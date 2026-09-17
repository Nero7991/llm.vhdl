-- rtl/fk33_seam.vhd -- THE HOST SEAM, IN FRONT OF SUBSYSTEM D.
-- TRACK DSEAM, 2026-08-30.  Closes board row N2 option (a).
--
-- WHY IT IS IN `rtl/` AND NOT IN `hw/fk33/rtl/`, WHERE THE NAME SUGGESTS.
-- MEASURED: `sim/regress.sh`'s planner globs design units out of `rtl/`,
-- `sim/`, `sim/micro/` and `tb/` and nothing else, so the first run of
-- `sim/tb_fk33_seam.vhd` against a copy in `hw/fk33/rtl/` reported
--     SKIPPED  sim:tb_fk33_seam  unresolved design unit(s): fk33_seam
-- and still printed `REGRESSION: PASS` with `PASS 0`.  A block that cannot
-- be a gate row is a block nothing gates, and this repository already has
-- five such files -- `rtl/seq_top_skel.vhd` among them -- listed in that
-- runner's own "reached by no testbench" section.
--
-- It also is not board-specific in any real sense: no UNISIM primitive, no
-- FK33 pin, no clocking, one AXI4-Lite slave port.  `hw/fk33/rtl/` holds the
-- GENERATED tops and the thermal guard, which are.  The name keeps `fk33_`
-- because `server/fk33_seam.h` is the other half of the contract and the two
-- must be greppable together.
--
-- Oren, 2026-08-30, verbatim: "we don't want host controlling, let's get D
-- working".  That selected option (a) of board row N2 -- an `fk33_seam`
-- AXI-Lite block in front of subsystem D -- and rejected option (b), which
-- was to retarget `server/pl_backend.c` at the descriptor plane and let the
-- host own the step loop.  This file is that block.
--
-- ======================================================================
-- WHAT IT IS, IN ONE SENTENCE
-- ======================================================================
-- An AXI4-Lite slave that owns the four things `rtl/llama_top.vhd` needs
-- from a host every token -- the descriptor program, the per-step release
-- mask, the input activation and the go/done handshake -- and presents them
-- as REGISTERS AND WINDOWS the host writes ONCE PER TOKEN OR ONCE PER MODEL,
-- never once per step.
--
-- The measurement that makes that the point, and the one to read before
-- expecting anything else of it: fitting the card's own cycle counters
-- across a 6x range of job size gives CYCLES = 21.67 * BEATS + 215.  The
-- 215-cycle intercept is 1.07 us, so the per-job setup this block amortises
-- is worth 0.33 ms across a whole 311-job token.  The 21.67 cycles per beat
-- is per-beat, does not amortise, and NOTHING IN THIS FILE TOUCHES IT.  D is
-- not a speedup of the engine; it is the removal of ~8.4 s of per-job MMIO
-- from a 17.8 s token.  See the N2 block in docs/WORKLOG.md.
--
-- ======================================================================
-- THE FIVE HOST INPUTS D HAS, AND WHERE EACH ONE COMES FROM NOW
-- ======================================================================
-- `rtl/llama_top.vhd`'s host face is `go`, `abort`, `tbl_len`, `host_x_exp`,
-- `rel_mask`, `tok_ack`, the descriptor read port `d_raddr`/`d_ren`/
-- `d_rdata`/`d_rvalid`, and the region access ports `hw_*`/`hr_*`.  Until
-- this file every one of them was driven by a TESTBENCH PROCESS, and two of
-- them were driven PER STEP:
--
--   `rel_mask`  -- `sim/tb_llama_top.vhd:1923` publishes `PLAN(n_chk).rel`,
--                  one 14-bit mask per step, advanced on `obs_issue`.  A
--                  host doing that over PCIe would be back inside the inner
--                  loop, which is exactly what Oren ruled out.
--   `d_rdata`   -- a descriptor memory model, one 64-bit word per read.
--
-- Here:
--
--   `rel_mask`  -- a REL RAM, `REL_ENT` entries of `NREG` bits, written once
--                  per model through the indirect window, and indexed by a
--                  counter this block advances on `obs_issue` and clears on
--                  `go`.  That counter reproduces the bench's own proxy
--                  EXACTLY (`sim/tb_llama_top.vhd:1927-1945`), which is why
--                  the numbers do not move: see `sim/tb_fk33_seam.vhd`.
--   `d_rdata`   -- a DESCRIPTOR RAM, `DESC_WORDS` 64-bit words, written once
--                  per model through the same window, read back at one-cycle
--                  registered latency.
--   `host_x_exp`, `tbl_len` -- registers, written once per token and once per
--                  model respectively.
--   `hw_*`      -- the X window: one 16-bit mantissa per 32-bit AXI write,
--                  once per token.
--   `hr_*`      -- the readback window, for R_X after `tok_done`.
--   `go`/`tok_ack` -- CTRL bit 0 raises `go` for one cycle; `tok_ack` is
--                  raised BY THIS BLOCK when it has latched `tok_done`.  A
--                  host round trip to acknowledge a completion it is already
--                  polling for would be a round trip that buys nothing.
--
-- ======================================================================
-- WHAT IS STILL HOST-SIDE AFTER THIS BLOCK.  READ THIS BEFORE QUOTING IT.
-- ======================================================================
--  1. THE TOKEN LOOP.  One GO is one position.  Sampling, the chat template,
--     detokenization, stop strings and the decision to run another position
--     are the host's and are meant to be: `server/fk33_seam.h`'s own
--     derivation puts a PCIe round trip at ~0.1% of a 38.27 ms token.
--  2. THE EMBEDDING GATHER.  The card does not read the embedding table.  The
--     host dequantizes and BFP-packs the row and pushes `n_embd` mantissas
--     plus one exponent.  That is `fk33_seam.h`'s stated ownership split and
--     this block implements it unchanged.
--  3. THE FULL LOGITS.  This block returns the sampler's ARGMAX and its
--     shared exponent.  It does NOT return 248,320 s32 logits: there is no
--     C2H path here, and pulling them through this window would be 993,280
--     non-posted BAR reads.  A host that needs real logits needs the DMA
--     that N3 has to build; a greedy host does not.
--  4. EVERYTHING BETWEEN THE MATVECS ON THE CARD THAT IS NOT ON THE CARD.
--     `hw/fk33/rtl/fk33_engine.vhd` still instantiates `matvec_int4_desc_axi`
--     and nothing else, so subsystems B, C and D have never run on this
--     silicon.  This block being correct in simulation says nothing about
--     that, and the 32 re-anchors per token that
--     `hw/fk33/host/fk33_run_token.py` counts are still 32.
--
-- ======================================================================
-- WHY INDIRECT WINDOWS AND NOT THE HBM POINTERS THE HEADER DECLARES
-- ======================================================================
-- `server/fk33_seam.h` v1 declares X_BASE, L_BASE and DESC_PTR: pointers to
-- blocks the CARD fetches out of HBM.  That is the right long-term shape and
-- it is NOT what this block implements, for one reason that is structural
-- rather than a preference: FETCHING THEM NEEDS AN HBM MASTER THIS BLOCK
-- DOES NOT HAVE.  Subsystem A already takes 27 of the 30 engine HBM ports
-- (`docs/2026-08-28_token-io-path.md`), the port assignment lives in
-- `hw/fk33/gen_pcieep.py`, and inventing a 31st master here would be a
-- contested claim on a file this track does not own.
--
-- So v2 of the contract implements the same seam over the BAR:
--
--   * the descriptor program and the release table are written ONCE PER
--     MODEL.  They do not change between tokens.  At the 9B shape that is
--     505 descriptors = 4,040 64-bit words = 8,080 posted writes, plus 505
--     mask writes, ONCE.  Amortised over a generation it is zero.
--
--     505 IS DERIVED, and it is NOT the 546 that `rtl/seq_desc_fetch.vhd`'s
--     own header quotes.  `llama_map_pkg.n_steps` is
--     `24*16 + 8*13 + 3 = 491` at QWEN35_9B, and `llama_sched_pkg.build_table`
--     runs `n_steps - 1 + lm_windows = 491 - 1 + 15 = 505` because the lm_head
--     is fifteen row windows.  `sim/llama_sched_pkg.vhd:88` says the same in
--     its own words.  Where a comment and the RTL disagree, the RTL wins.
--   * the activation row is written ONCE PER TOKEN: n_embd = 4,096
--     mantissas = 2,048 posted 32-bit writes.  ESTIMATE, and the assumption
--     is stated because it has never been measured on this card: posted
--     writes pipeline, so this is bounded by link bandwidth and not by the
--     1-2 us non-posted BAR READ latency that makes MMIO readback hopeless.
--     `docs/2026-08-28_token-io-path.md` says explicitly that no
--     small-transfer latency has ever been measured here, so treat the cost
--     as UNMEASURED rather than small.
--   * X_BASE/L_BASE/DESC_PTR remain in the header, remain reserved here, and
--     MUST BE ZERO at GO.  A non-zero one raises FK33_SEAM_ERR_RSVD rather
--     than being silently ignored, because a host that thinks it handed the
--     card a pointer and got a token back would have been lied to.
--
-- ======================================================================
-- THE ERROR DISCIPLINE, INHERITED DELIBERATELY
-- ======================================================================
-- ON ANY ERROR, `done` IS NEVER SET.  That is subsystem A's rule
-- (`docs/2026-08-28_matvec-descriptor-format.md`) and `fk33_seam.h` restates
-- it: a done-only poller hangs forever.  Poll (done | err).
--
-- D's OWN 4-bit `err_code` IS NOT THE SEAM'S 4-bit code.  D reports
-- ERR_DESC/ERR_EPOCH/ERR_WDOG/... in its own space and A's space is full
-- (OI-9); a shared field with two meanings per value is how an error report
-- becomes fiction.  So a D error surfaces as seam code FK33_SEAM_ERR_DESC
-- with D's own code carried, separately, in ERR_INFO[3:0].
--
-- ======================================================================
-- WHAT THIS FILE DOES NOT DO
-- ======================================================================
--  * It does not talk to HBM.  No AXI master, of any width, in any direction.
--  * It does not sample.  `rtl/sampler_stream.vhd` inside `llama_top` does;
--    this block only publishes what that stream already produced.
--  * It does not check the descriptor program.  `rtl/seq_desc_fetch.vhd` and
--    `rtl/seq_opdec.vhd` do, before any unit starts, and their refusal is
--    what ERR_DESC reports.  A second checker here would be a competing
--    claim, not a check.
--  * It has NEVER RUN ON SILICON, and neither has the thing behind it.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
-- `clog2`, for the region-access port widths below.  This file otherwise
-- depends on ieee only, and the dependency is SAFE for the block design:
-- `hw/fk33/build_fk33_pcieep.tcl` already adds `rtl/util_pkg.vhd` to the
-- project (it is a dependency of the engine), so `create_bd_cell -reference
-- fk33_seam` can resolve it.
use work.util_pkg.all;

entity fk33_seam is
  generic(
    -- ---- geometry, and it must AGREE with the llama_top it drives -------
    NREG    : positive := 14;     -- activation regions; rel-mask width
    -- THE REGION-ACCESS PORT WIDTHS ARE GENERICS, NOT A clog2 CALL, AND THAT
    -- IS A VIVADO CONSTRAINT.  The IP packager evaluates a port's width as an
    -- XPath expression over the generics and cannot call a VHDL function:
    --   ERROR: [IP_Flow 19-627] Port 'hw_reg': XPath expression failed:
    --   Unsupported function call or array usage "clog2"
    -- so sizing these ports by a function fails `create_bd_cell` exactly as
    -- `natural` did.  Arithmetic on a generic is fine; a function call is not.
    -- MEASURED 2026-09-03, both errors in turn:
    -- docs/debugging/2026-09-03_pcieep-build-two-blockers.md.
    -- Defaults are clog2(14) = 4 and clog2(4096) = 12.
    --
    -- THEY CANNOT DRIFT: the architecture refuses any value that is not
    -- exactly clog2 of its region count, in BOTH directions, by the
    -- out-of-range-natural idiom this project uses because Vivado silently
    -- ignores `assert ... severity failure` in synthesis.
    HREG_W  : positive := 4;      -- must equal clog2(NREG)
    HADDR_W : positive := 12;     -- must equal clog2(REGMAX)
    REGMAX  : positive := 4096;   -- elements in the widest region
    XREG    : natural  := 0;      -- the region the host writes (R_X)
    STEP_W  : positive := 11;
    EXP_W   : positive := 16;
    MANT_W  : positive := 16;
    -- ---- window capacities ---------------------------------------------
    -- 64-bit descriptor words.  8 per descriptor: 4,040 at the 9B shape.
    DESC_WORDS : positive := 4608;
    -- Release-mask entries.  One per step, so >= the longest table.
    REL_ENT    : positive := 576;
    -- ---- identity, read back by the host so it cannot disagree ---------
    CAPS_VOCAB : natural := 0;
    CAPS_EMBD  : natural := 0;
    CAPS_LAYER : natural := 0;
    CAPS_CTX   : natural := 0;
    -- Positions this card can be at.  SEQ_POS is checked against the card's
    -- own next position, so a host that loses count is refused rather than
    -- silently attending over the wrong history.
    MAXPOS     : positive := 4;
    -- Simulation-only protocol assertions.  Synthesise to nothing.
    STRICT     : boolean  := false
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ================== AXI4-LITE SLAVE, 32-bit, 4 KB =================
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_awaddr  : in  std_logic_vector(11 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_wdata   : in  std_logic_vector(31 downto 0);
    s_axi_wstrb   : in  std_logic_vector(3 downto 0) := (others => '1');
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_araddr  : in  std_logic_vector(11 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic;
    s_axi_rdata   : out std_logic_vector(31 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);

    -- ======================= SUBSYSTEM D, CONTROL =====================
    d_go         : out std_logic;
    d_abort      : out std_logic;
    d_tbl_len    : out unsigned(STEP_W-1 downto 0);
    d_host_x_exp : out signed(EXP_W-1 downto 0);
    d_rel_mask   : out std_logic_vector(NREG-1 downto 0);
    d_tok_ack    : out std_logic;

    d_busy       : in  std_logic;
    d_tok_done   : in  std_logic;
    d_err        : in  std_logic;
    d_err_code   : in  std_logic_vector(3 downto 0);
    d_err_step   : in  unsigned(STEP_W-1 downto 0);
    d_steps_done : in  unsigned(STEP_W-1 downto 0);

    -- ==================== DESCRIPTOR MEMORY, D IS THE MASTER ===========
    d_raddr      : in  unsigned(15 downto 0);
    d_ren        : in  std_logic;
    d_rdata      : out std_logic_vector(63 downto 0);
    d_rvalid     : out std_logic;

    -- ======================== REGION ACCESS PORTS ======================
    hw_we        : out std_logic;
    -- SLV, NOT `natural`, AND THAT IS A BUILD REQUIREMENT RATHER THAN A
    -- STYLE CHOICE.  Vivado's block-design module inference refuses a
    -- `natural` port outright -- "[IP_Flow 19-734] Port type 'natural' is not
    -- recognized.  Only std_logic and std_logic_vector types are allowed for
    -- ports" -- and `hw/fk33/gen_pcieep.py` adds this entity to the BD with
    -- `create_bd_cell -type module -reference fk33_seam`.  With these four as
    -- `natural` that call FAILS and no bitstream can be built at all.
    -- MEASURED 2026-09-03, docs/debugging/2026-09-03_pcieep-build-two-blockers.md.
    --
    -- `clog2(n)` is the width holding 0 .. n-1, so NREG=14 gives 4 bits and
    -- REGMAX=4096 gives 12.  NREG=1 would give a null range; it is not a real
    -- configuration and nothing instantiates it that way.
    hw_reg       : out std_logic_vector(HREG_W-1 downto 0);
    hw_addr      : out std_logic_vector(HADDR_W-1 downto 0);
    hw_data      : out signed(MANT_W-1 downto 0);
    hr_reg       : out std_logic_vector(HREG_W-1 downto 0);
    hr_addr      : out std_logic_vector(HADDR_W-1 downto 0);
    hr_data      : in  signed(MANT_W-1 downto 0);

    -- ============================ OBSERVATION ==========================
    -- `obs_issue` is one cycle per step and is the ONLY thing that advances
    -- the release-mask index.  See the note on the rel counter below: this
    -- is not a convenience, it is the bench's own proven proxy for the
    -- internal `chk_req` that `llama_top` does not export.
    obs_issue    : in  std_logic;
    obs_tok_pos  : in  unsigned(15 downto 0) := (others => '0');

    -- The sampler's published result.  `smp_token` is the RUNNING argmax and
    -- is final at `tok_done`; `smp_done` pulses per lm_head WINDOW, not per
    -- token, so this block deliberately does not use it as a completion.
    smp_token    : in  unsigned(31 downto 0) := (others => '0');
    smp_n        : in  unsigned(31 downto 0) := (others => '0');
    smp_exp      : in  signed(EXP_W-1 downto 0) := (others => '0');

    -- The five sticky seam faults `llama_top` publishes, plus the KV one.
    -- Every one of these is a DEFECT, not a statistic, and every one is
    -- silent in the arithmetic, which is why they get a register.
    f_smp_ovf    : in  std_logic := '0';
    f_lost_beat  : in  std_logic := '0';
    f_gate_drop  : in  std_logic := '0';
    f_unit_stub  : in  std_logic := '0';
    f_e_coll     : in  std_logic := '0';
    f_kv_err     : in  std_logic := '0'
  );
end entity;

architecture rtl of fk33_seam is
  -- A WIDTH GENERIC THAT DOES NOT MATCH ITS REGION COUNT IS REFUSED, in both
  -- directions, so the Vivado workaround above cannot silently truncate an
  -- address or widen a port past what the BD wires.  Too small and the first
  -- of each pair goes negative; too large and the second does.
  constant bad_hreg_w_small  : natural := HREG_W - clog2(NREG);
  constant bad_hreg_w_big    : natural := clog2(NREG) - HREG_W;
  constant bad_haddr_w_small : natural := HADDR_W - clog2(REGMAX);
  constant bad_haddr_w_big   : natural := clog2(REGMAX) - HADDR_W;


  -- ---------------- the register map, byte offsets --------------------
  -- 0x00..0x48 are `server/fk33_seam.h` v1, unchanged.
  -- 0x4C..0x6C are v2 and are the ones this block adds.
  constant A_ID         : natural := 16#00#;
  constant A_VERSION    : natural := 16#04#;
  constant A_CAPS_VOCAB : natural := 16#08#;
  constant A_CAPS_EMBD  : natural := 16#0C#;
  constant A_CAPS_CTX   : natural := 16#10#;
  constant A_CTRL       : natural := 16#14#;
  constant A_STATUS     : natural := 16#18#;
  constant A_ERR_INFO   : natural := 16#1C#;
  constant A_SEQ_POS    : natural := 16#20#;
  constant A_N_STEP     : natural := 16#24#;
  constant A_X_BASE_LO  : natural := 16#28#;
  constant A_X_BASE_HI  : natural := 16#2C#;
  constant A_L_BASE_LO  : natural := 16#30#;
  constant A_L_BASE_HI  : natural := 16#34#;
  constant A_DESC_LO    : natural := 16#38#;
  constant A_DESC_HI    : natural := 16#3C#;
  constant A_CYCLES     : natural := 16#40#;
  constant A_ARGMAX     : natural := 16#44#;
  constant A_LOGIT_EXP  : natural := 16#48#;
  constant A_CAPS_FLAGS : natural := 16#4C#;
  constant A_TBL_LEN    : natural := 16#50#;
  constant A_X_EXP      : natural := 16#54#;
  constant A_WIN_SEL    : natural := 16#58#;
  constant A_WIN_ADDR   : natural := 16#5C#;
  constant A_WIN_DATA   : natural := 16#60#;
  constant A_SMP_N      : natural := 16#64#;
  constant A_FAULTS     : natural := 16#68#;

  constant ID_MAGIC : std_logic_vector(31 downto 0) := x"4C4C4D32";
  constant VERSION2 : natural := 2;

  -- CAPS_FLAGS.  What this bitstream ACTUALLY implements, so a host cannot
  -- discover it by trying.  Bit 1 is 0 here and that is the honest report.
  --   bit 0  indirect windows present
  --   bit 1  HBM pointer fetch (X_BASE/L_BASE/DESC_PTR) present
  --   bit 2  sampler argmax published
  --   bit 3  full logits egress present
  -- CORRECTED 2026-09-11: was x"00000005", which SET bit 2 and told every host
  -- this bitstream publishes a sampler argmax.  It does not.  The card leaves
  -- `SMP_EN` at llama_top's default of FALSE, which ties the entire logits
  -- stream off, so bit 2 advertised hardware that is not in the design.
  --
  -- A host that reads CAPS_FLAGS and believes it waits for an argmax that never
  -- arrives: no error, no timeout from the card, nothing in a log -- which is
  -- precisely the discovery-by-trying this constant exists to prevent.
  -- docs/PLAN_TO_FIRST_INFERENCE.md:644 recorded it and nothing enforced it.
  --
  -- Now enforced by `check_seam_regs.py`'s CAPS:SAMPLER row, which derives the
  -- expectation from gen_fk33_card.py's SMP_EN rather than hardcoding a value,
  -- so BUILDING the sampler and setting this bit back is the other way to make
  -- it pass.  Bit 1 was already 0 and its comment calls that "the honest
  -- report"; this makes bit 2 honest too.
  constant CAPS_FLAGS_V : std_logic_vector(31 downto 0) := x"00000001";

  -- seam error codes, `server/fk33_seam.h`
  constant EC_NONE  : natural := 0;
  constant EC_POS   : natural := 1;
  constant EC_NSTEP : natural := 2;
  constant EC_RSVD  : natural := 5;
  constant EC_DESC  : natural := 6;
  constant EC_SEQ   : natural := 8;

  -- window selectors
  constant W_DESC : natural := 0;
  constant W_REL  : natural := 1;
  constant W_XIN  : natural := 2;
  constant W_XOUT : natural := 3;

  -- ------------------------------- memories ---------------------------
  -- ==================================================================
  -- `desc_ram` IS BLOCK RAM, NOT LUTRAM, AND THAT IS A PLACEMENT FIX.
  --
  -- 4,608 x 64 = 294,912 bits.  Left to infer, Vivado puts it in distributed
  -- RAM, and MEASURED 2026-09-16 on the first full FK33_CARD=1 build that is
  -- most of `fk33_seam_0`'s 11,083 LUT -- 9,468 of them LUTRAM against just
  -- 888 FF, which is the signature of storage rather than datapath.
  --
  -- WHY IT MATTERS: that build SYNTHESISED clean and then FAILED PLACEMENT --
  -- `[Place 30-487] ... 36345 CLBs required, 35902 available`, short by 443 --
  -- with CLB LUTs at 98.84%.  LUT is the full dimension; block RAM is at 437
  -- tiles of 672 and this needs roughly 9 to 16 of the 235 spare.  Moving
  -- storage off the LUT array is the cheapest LUT there is to give back,
  -- because it buys CLBs without touching any arithmetic.
  --
  -- IT CHANGES NO BEHAVIOUR, BY CONSTRUCTION.  `ram_style` is a synthesis
  -- attribute; GHDL ignores it, so every bench result is bit-identical before
  -- and after.  What it can do is be REFUSED -- `[Synth 8-6849] Infeasible
  -- attribute ram_style = "block"` -- and fall back to LUTRAM silently enough
  -- that only the utilization report shows it.  rtl/region_mem.vhd records the
  -- discriminator: at THREE read sites Vivado refuses and at TWO it accepts.
  --
  -- THIS MEMORY HAS EXACTLY ONE WRITE SITE AND TWO READ SITES, and both reads
  -- are inside clocked processes off registered addresses:
  --   write   :743/:745  the host WIN_DATA stream, 32 bits at a time
  --   read    :524       `dq_data <= desc_ram(a)`, the descriptor fetch
  --   read    :837/:839  the host readback, 32-bit half selected by parity
  -- A THIRD reader added later silently costs the BRAM and puts 9,468 LUT
  -- back.  Check the utilization report, not the log, if this ever regresses.
  -- ==================================================================
  type desc_ram_t is array (0 to DESC_WORDS-1)
       of std_logic_vector(63 downto 0);
  signal desc_ram : desc_ram_t := (others => (others => '0'));
  attribute ram_style : string;
  attribute ram_style of desc_ram : signal is "block";

  type rel_ram_t is array (0 to REL_ENT-1)
       of std_logic_vector(NREG-1 downto 0);
  signal rel_ram : rel_ram_t := (others => (others => '0'));

  -- THE OUTPUT REGISTER `desc_ram` NEEDS TO BE A BLOCK RAM.
  --
  -- MEASURED 2026-09-16: with `ram_style = "block"` and no register in the read
  -- fanout, Vivado answers
  --   [Synth 8-6850] RAM (desc_ram_reg) has partial Byte Wide Write Enable
  --     pattern with ram_style = "block", however no output register found in
  --     fanout of RAM
  --   [Synth 8-6849] Infeasible attribute ... trying to implement using LUTRAM
  -- and the 9,468 LUTRAM stay exactly where they were.  The descriptor-fetch
  -- read at :524 DOES register into `dq_data`; it is the host READBACK that
  -- reads into a variable, and a variable is not a register Vivado can see.
  --
  -- THIS COSTS NO AXI LATENCY.  The read channel already spends a dead cycle:
  -- `rd_wait` walks 0 -> 1 -> 2 -> 3 and state 1 only advances the counter.
  -- Registering the word there and consuming it in state 2 uses a cycle that
  -- was already being spent, so the host sees the identical handshake.
  signal desc_q : std_logic_vector(63 downto 0) := (others => '0');

  -- ------------------------------ registers ---------------------------
  signal r_seq_pos  : unsigned(31 downto 0) := (others => '0');
  signal r_n_step   : unsigned(31 downto 0) := to_unsigned(1, 32);
  signal r_x_base   : std_logic_vector(63 downto 0) := (others => '0');
  signal r_l_base   : std_logic_vector(63 downto 0) := (others => '0');
  signal r_desc_ptr : std_logic_vector(63 downto 0) := (others => '0');
  signal r_tbl_len  : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal r_x_exp    : signed(EXP_W-1 downto 0) := (others => '0');
  signal r_win_sel  : unsigned(1 downto 0) := (others => '0');
  signal r_win_addr : unsigned(15 downto 0) := (others => '0');

  signal r_cycles   : unsigned(31 downto 0) := (others => '0');
  signal r_argmax   : unsigned(31 downto 0) := (others => '0');
  signal r_logit_e  : signed(EXP_W-1 downto 0) := (others => '0');
  signal r_smp_n    : unsigned(31 downto 0) := (others => '0');

  -- ------------------------------ state -------------------------------
  signal st_done    : std_logic := '0';   -- latched, cleared by the next GO
  signal st_err     : std_logic := '0';   -- sticky until CLR_ERR or a GO
  signal st_code    : unsigned(3 downto 0) := (others => '0');
  signal st_dcode   : std_logic_vector(3 downto 0) := (others => '0');
  signal st_dstep   : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal st_dsteps  : unsigned(STEP_W-1 downto 0) := (others => '0');
  signal running    : std_logic := '0';   -- GO accepted, no completion yet
  signal cur_pos    : unsigned(31 downto 0) := (others => '0');

  signal go_r       : std_logic := '0';
  signal abort_r    : std_logic := '0';
  signal ack_r      : std_logic := '0';

  -- release-mask index.  Cleared at `go`, advanced at `obs_issue`.
  -- Saturating, with a separate end flag: an index one past the array is a
  -- bounds error in simulation even inside a guarded branch, and a guard
  -- whose guarded expression is still evaluated is not a guard.
  signal rel_idx    : natural range 0 to REL_ENT-1 := 0;
  signal rel_end    : std_logic := '0';

  -- host region write strobe
  signal xw_we      : std_logic := '0';
  signal xw_addr    : natural range 0 to REGMAX-1 := 0;
  signal xw_data    : signed(MANT_W-1 downto 0) := (others => '0');
  signal xr_addr    : natural range 0 to REGMAX-1 := 0;

  -- descriptor read pipeline
  signal dq_valid   : std_logic := '0';
  signal dq_data    : std_logic_vector(63 downto 0) := (others => '0');

  -- ------------------------------- AXI --------------------------------
  signal aw_hold    : std_logic := '0';
  signal w_hold     : std_logic := '0';
  signal aw_addr    : unsigned(11 downto 0) := (others => '0');
  signal w_data     : std_logic_vector(31 downto 0) := (others => '0');
  signal bvalid_i   : std_logic := '0';
  signal arready_i  : std_logic := '0';
  signal rvalid_i   : std_logic := '0';
  signal rdata_i    : std_logic_vector(31 downto 0) := (others => '0');
  -- Read latency state.  A WIN_DATA read in XOUT mode needs one clocked
  -- state for `hr_data` to settle, so every read takes the same path rather
  -- than only that one: a data-dependent read latency is the kind of detail
  -- that works in simulation and races on the card.
  signal rd_wait    : natural range 0 to 3 := 0;
  signal rd_addr    : unsigned(11 downto 0) := (others => '0');

  function to_slv32(u : unsigned) return std_logic_vector is
    variable v : unsigned(31 downto 0) := (others => '0');
  begin
    v(u'length-1 downto 0) := u;
    return std_logic_vector(v);
  end function;

begin

  -- ====================================================================
  -- OUTPUTS TO SUBSYSTEM D
  -- ====================================================================
  d_go         <= go_r;
  d_abort      <= abort_r;
  d_tok_ack    <= ack_r;
  d_tbl_len    <= r_tbl_len;
  d_host_x_exp <= r_x_exp;

  -- THE RELEASE MASK.  Published combinationally from the RAM, exactly as
  -- `sim/tb_llama_top.vhd:1923` publishes it from its PLAN array, and zero
  -- past the end of the table for exactly the reason recorded there: a stale
  -- index past NSTEP publishes a mask the walker refuses at err_code 3,
  -- which reads like a DUT fault and is bookkeeping.
  d_rel_mask <= rel_ram(rel_idx) when rel_end = '0'
                                  and rel_idx < to_integer(r_tbl_len)
                else (others => '0');

  relcnt : process(clk) is
  begin
    if rising_edge(clk) then
      if rst = '1' or go_r = '1' then
        rel_idx <= 0;
        rel_end <= '0';
      elsif obs_issue = '1' then
        if rel_idx = REL_ENT-1 then
          rel_end <= '1';
        else
          rel_idx <= rel_idx + 1;
        end if;
      end if;
    end if;
  end process;

  -- ====================================================================
  -- THE DESCRIPTOR MEMORY.  D is the only master; there is no arbitration
  -- and no ready.  One clocked state of latency, which is the fastest the
  -- bench's own model ever ran (`uram_lat = 1`), so this block cannot be
  -- the thing that hides a prefetch race that a slower memory would expose.
  -- ====================================================================
  dram : process(clk) is
    variable a : natural;
  begin
    if rising_edge(clk) then
      dq_valid <= '0';
      if rst = '1' then
        dq_valid <= '0';
      elsif d_ren = '1' then
        a := to_integer(d_raddr);
        if a < DESC_WORDS then
          dq_data <= desc_ram(a);
        else
          dq_data <= (others => '0');
        end if;
        dq_valid <= '1';
      end if;
    end if;
  end process;
  d_rdata  <= dq_data;
  d_rvalid <= dq_valid;

  -- ====================================================================
  -- THE REGION PORTS
  -- ====================================================================
  hw_we   <= xw_we;
  hw_reg  <= std_logic_vector(to_unsigned(XREG, hw_reg'length));
  hw_addr <= std_logic_vector(to_unsigned(xw_addr, hw_addr'length));
  hw_data <= xw_data;
  hr_reg  <= std_logic_vector(to_unsigned(XREG, hr_reg'length));
  hr_addr <= std_logic_vector(to_unsigned(xr_addr, hr_addr'length));

  -- ====================================================================
  -- AXI4-LITE WRITE CHANNEL
  -- ====================================================================
  s_axi_awready <= not aw_hold;
  s_axi_wready  <= not w_hold;
  s_axi_bvalid  <= bvalid_i;
  s_axi_bresp   <= "00";

  -- ====================================================================
  -- AXI4-LITE READ CHANNEL
  -- ====================================================================
  s_axi_arready <= arready_i;
  s_axi_rvalid  <= rvalid_i;
  s_axi_rdata   <= rdata_i;
  s_axi_rresp   <= "00";

  main : process(clk) is
    variable off  : natural;
    variable wr   : boolean;
    variable dat  : std_logic_vector(31 downto 0);
    variable idx  : natural;
    variable roff : natural;
    variable rv   : std_logic_vector(31 downto 0);
    variable bad  : natural;
  begin
    if rising_edge(clk) then

      -- ---- one-cycle strobes ------------------------------------------
      go_r    <= '0';
      abort_r <= '0';
      ack_r   <= '0';
      xw_we   <= '0';

      if rst = '1' then
        aw_hold   <= '0'; w_hold <= '0'; bvalid_i <= '0';
        arready_i <= '1'; rvalid_i <= '0'; rd_wait <= 0;
        st_done   <= '0'; st_err <= '0'; st_code <= (others => '0');
        running   <= '0'; cur_pos <= (others => '0');
        r_seq_pos <= (others => '0');
        r_n_step  <= to_unsigned(1, 32);
        r_x_base  <= (others => '0');
        r_l_base  <= (others => '0');
        r_desc_ptr<= (others => '0');
        r_tbl_len <= (others => '0');
        r_x_exp   <= (others => '0');
        r_win_sel <= (others => '0');
        r_win_addr<= (others => '0');
        r_cycles  <= (others => '0');
        r_argmax  <= (others => '0');
        r_logit_e <= (others => '0');
        r_smp_n   <= (others => '0');
        st_dcode  <= (others => '0');
        st_dstep  <= (others => '0');
        st_dsteps <= (others => '0');
      else

        -- ==============================================================
        -- COMPLETION.  `tok_done` is a LEVEL held until `tok_ack`, and this
        -- block is the sole acknowledger.  D's error is captured at the
        -- SAME instant, because a unit that drops `err` after `done` must
        -- not be able to erase what it reported -- the same rule
        -- `seq_desc_fetch` applies one level down.
        -- ==============================================================
        if running = '1' then
          r_cycles <= r_cycles + 1;
          if d_err = '1' then
            st_err   <= '1';
            st_code  <= to_unsigned(EC_DESC, 4);
            st_dcode <= d_err_code;
            st_dstep <= d_err_step;
            st_dsteps<= d_steps_done;
            running  <= '0';
            ack_r    <= '1';
          elsif d_tok_done = '1' then
            st_done  <= '1';
            st_dsteps<= d_steps_done;
            r_argmax <= smp_token;
            r_smp_n  <= smp_n;
            r_logit_e<= smp_exp;
            running  <= '0';
            ack_r    <= '1';
            if cur_pos < MAXPOS then
              cur_pos <= cur_pos + 1;
            end if;
          end if;
        end if;

        -- ==============================================================
        -- WRITE CHANNEL
        -- ==============================================================
        if s_axi_awvalid = '1' and aw_hold = '0' then
          aw_addr <= unsigned(s_axi_awaddr);
          aw_hold <= '1';
        end if;
        if s_axi_wvalid = '1' and w_hold = '0' then
          w_data <= s_axi_wdata;
          w_hold <= '1';
        end if;

        wr := false;
        if aw_hold = '1' and w_hold = '1' and bvalid_i = '0' then
          wr  := true;
          off := to_integer(aw_addr(11 downto 2)) * 4;
          dat := w_data;
          aw_hold  <= '0';
          w_hold   <= '0';
          bvalid_i <= '1';
        else
          off := 0;
          dat := (others => '0');
        end if;

        if bvalid_i = '1' and s_axi_bready = '1' then
          bvalid_i <= '0';
        end if;

        if wr then
          case off is

            when A_CTRL =>
              -- bit 3 ABORT and bit 5 CLR_ERR act whatever the state.
              if dat(3) = '1' then
                abort_r <= '1';
                running <= '0';
              end if;
              if dat(5) = '1' then
                st_err  <= '0';
                st_code <= (others => '0');
              end if;
              if dat(1) = '1' then          -- SEQ_RESET
                cur_pos   <= (others => '0');
                r_seq_pos <= (others => '0');
              end if;
              if dat(0) = '1' then          -- GO
                -- Clear the previous token's verdict FIRST, so a stale DONE
                -- can never be read as this token's.
                st_done  <= '0';
                st_err   <= '0';
                st_code  <= (others => '0');
                st_dcode <= (others => '0');
                st_dstep <= (others => '0');
                r_cycles <= (others => '0');
                -- ---- the GO-time checks.  ON ANY FAILURE `go` IS NOT
                -- ---- RAISED AND `done` IS NEVER SET.
                bad := EC_NONE;
                if r_n_step /= 1 then
                  bad := EC_NSTEP;          -- one position per GO in v2
                elsif r_tbl_len = 0
                   or to_integer(r_tbl_len) > REL_ENT
                   or to_integer(r_tbl_len) * 8 > DESC_WORDS then
                  bad := EC_NSTEP;
                elsif unsigned(r_x_base) /= 0
                   or unsigned(r_l_base) /= 0
                   or unsigned(r_desc_ptr) /= 0 then
                  bad := EC_RSVD;           -- v2 has no HBM master.  Say so.
                elsif r_seq_pos /= cur_pos then
                  bad := EC_SEQ;
                elsif cur_pos >= MAXPOS then
                  bad := EC_POS;
                elsif running = '1' or d_busy = '1' then
                  bad := EC_SEQ;
                end if;
                if bad = EC_NONE then
                  go_r    <= '1';
                  running <= '1';
                else
                  st_err  <= '1';
                  st_code <= to_unsigned(bad, 4);
                end if;
              end if;

            when A_SEQ_POS   => r_seq_pos <= unsigned(dat);
            when A_N_STEP    => r_n_step  <= unsigned(dat);
            when A_X_BASE_LO => r_x_base(31 downto 0)  <= dat;
            when A_X_BASE_HI => r_x_base(63 downto 32) <= dat;
            when A_L_BASE_LO => r_l_base(31 downto 0)  <= dat;
            when A_L_BASE_HI => r_l_base(63 downto 32) <= dat;
            when A_DESC_LO   => r_desc_ptr(31 downto 0)  <= dat;
            when A_DESC_HI   => r_desc_ptr(63 downto 32) <= dat;
            when A_TBL_LEN   => r_tbl_len <= resize(unsigned(dat), STEP_W);
            when A_X_EXP     => r_x_exp   <= resize(signed(dat), EXP_W);
            when A_WIN_SEL   => r_win_sel <= unsigned(dat(1 downto 0));
            when A_WIN_ADDR  =>
              r_win_addr <= unsigned(dat(15 downto 0));
              if to_integer(r_win_sel) = W_XOUT
                 and to_integer(unsigned(dat(15 downto 0))) < REGMAX then
                xr_addr <= to_integer(unsigned(dat(15 downto 0)));
              end if;

            when A_WIN_DATA =>
              idx := to_integer(r_win_addr);
              case to_integer(r_win_sel) is
                when W_DESC =>
                  -- WIN_ADDR indexes 32-BIT HALVES, low half first, so a
                  -- 64-bit descriptor word w is halves 2w and 2w+1.  A host
                  -- writing a byte image in order needs no shuffling.
                  if idx / 2 < DESC_WORDS then
                    if idx mod 2 = 0 then
                      desc_ram(idx/2)(31 downto 0)  <= dat;
                    else
                      desc_ram(idx/2)(63 downto 32) <= dat;
                    end if;
                  end if;
                when W_REL =>
                  if idx < REL_ENT then
                    rel_ram(idx) <= dat(NREG-1 downto 0);
                  end if;
                when W_XIN =>
                  -- Refused while a token is in flight.  The region lock's
                  -- window belongs to a JOB; this port is the one writer it
                  -- does not police, and that is only safe before any job
                  -- exists.
                  if idx < REGMAX and running = '0' and d_busy = '0' then
                    xw_we   <= '1';
                    xw_addr <= idx;
                    xw_data <= signed(dat(MANT_W-1 downto 0));
                  end if;
                when others =>
                  null;                       -- W_XOUT is read-only
              end case;
              r_win_addr <= r_win_addr + 1;
              if to_integer(r_win_sel) = W_XOUT
                 and to_integer(r_win_addr) + 1 < REGMAX then
                xr_addr <= to_integer(r_win_addr) + 1;
              end if;

            when others => null;
          end case;
        end if;

        -- ==============================================================
        -- READ CHANNEL.  Every read takes the same two clocked states.
        -- ==============================================================
        if arready_i = '1' and s_axi_arvalid = '1' then
          rd_addr   <= unsigned(s_axi_araddr);
          arready_i <= '0';
          rd_wait   <= 1;
          -- A WIN_DATA read in XOUT mode needs `hr_addr` presented now.
          if to_integer(unsigned(s_axi_araddr(11 downto 2))) * 4 = A_WIN_DATA
             and to_integer(r_win_sel) = W_XOUT
             and to_integer(r_win_addr) < REGMAX then
            xr_addr <= to_integer(r_win_addr);
          end if;
        elsif rd_wait = 1 then
          -- The output register.  Unconditional: `r_win_addr` is stable for the
          -- duration of a read, and reading a word we then discard costs
          -- nothing but makes this a clean single-address BRAM port.
          if to_integer(r_win_addr)/2 < DESC_WORDS then
            desc_q <= desc_ram(to_integer(r_win_addr)/2);
          else
            desc_q <= (others => '0');
          end if;
          rd_wait <= 2;
        elsif rd_wait = 2 then
          roff := to_integer(rd_addr(11 downto 2)) * 4;
          rv   := (others => '0');
          case roff is
            when A_ID         => rv := ID_MAGIC;
            when A_VERSION    => rv := to_slv32(to_unsigned(VERSION2, 32));
            when A_CAPS_VOCAB => rv := to_slv32(to_unsigned(CAPS_VOCAB, 32));
            when A_CAPS_EMBD  =>
              rv := std_logic_vector(to_unsigned(CAPS_LAYER, 16))
                  & std_logic_vector(to_unsigned(CAPS_EMBD, 16));
            when A_CAPS_CTX   => rv := to_slv32(to_unsigned(CAPS_CTX, 32));
            when A_CAPS_FLAGS => rv := CAPS_FLAGS_V;
            when A_STATUS     =>
              rv(0) := st_done;
              rv(1) := running or d_busy;
              rv(2) := st_err;
              rv(11 downto 8) := std_logic_vector(st_code);
            when A_ERR_INFO   =>
              -- D's OWN code in [3:0], the step it failed on in [14:4], and
              -- the descriptor count it actually completed in [26:16].  The
              -- last one is the accounting identity `seq_desc_fetch` checks
              -- itself: it must equal TBL_LEN at a clean completion.
              rv(3 downto 0)   := st_dcode;
              rv(4+STEP_W-1 downto 4)   := std_logic_vector(st_dstep);
              rv(16+STEP_W-1 downto 16) := std_logic_vector(st_dsteps);
            when A_SEQ_POS    => rv := std_logic_vector(cur_pos);
            when A_N_STEP     => rv := std_logic_vector(r_n_step);
            when A_TBL_LEN    => rv := to_slv32(r_tbl_len);
            when A_X_EXP      => rv := std_logic_vector(resize(r_x_exp, 32));
            when A_WIN_SEL    => rv := to_slv32(r_win_sel);
            when A_WIN_ADDR   => rv := to_slv32(r_win_addr);
            when A_CYCLES     => rv := std_logic_vector(r_cycles);
            when A_ARGMAX     => rv := std_logic_vector(r_argmax);
            when A_LOGIT_EXP  => rv := std_logic_vector(resize(r_logit_e, 32));
            when A_SMP_N      => rv := std_logic_vector(r_smp_n);
            when A_FAULTS     =>
              rv(0) := f_smp_ovf;
              rv(1) := f_lost_beat;
              rv(2) := f_gate_drop;
              rv(3) := f_unit_stub;
              rv(4) := f_e_coll;
              rv(5) := f_kv_err;
            when A_WIN_DATA   =>
              case to_integer(r_win_sel) is
                when W_DESC =>
                  -- `desc_q`, not `desc_ram`, so this is the memory's ONLY
                  -- readback port and it is registered.  Same word, same cycle,
                  -- captured one state earlier.  Indexing `desc_ram` here again
                  -- would restore the second read site and silently cost the
                  -- block RAM.
                  if to_integer(r_win_addr)/2 < DESC_WORDS then
                    if to_integer(r_win_addr) mod 2 = 0 then
                      rv := desc_q(31 downto 0);
                    else
                      rv := desc_q(63 downto 32);
                    end if;
                  end if;
                when W_REL =>
                  if to_integer(r_win_addr) < REL_ENT then
                    rv(NREG-1 downto 0) := rel_ram(to_integer(r_win_addr));
                  end if;
                when W_XOUT =>
                  rv := std_logic_vector(resize(hr_data, 32));
                when others =>
                  null;
              end case;
            when others => null;
          end case;
          rdata_i  <= rv;
          rvalid_i <= '1';
          rd_wait  <= 3;
          -- The window auto-increments on a DATA read too, so a host can
          -- stream a region out without one address write per element.
          if roff = A_WIN_DATA then
            r_win_addr <= r_win_addr + 1;
            if to_integer(r_win_sel) = W_XOUT
               and to_integer(r_win_addr) + 1 < REGMAX then
              xr_addr <= to_integer(r_win_addr) + 1;
            end if;
          end if;
        elsif rd_wait = 3 then
          if rvalid_i = '1' and s_axi_rready = '1' then
            rvalid_i  <= '0';
            arready_i <= '1';
            rd_wait   <= 0;
          end if;
        end if;

      end if;
    end if;
  end process;

  -- ====================================================================
  -- SIMULATION-ONLY PROTOCOL ASSERTIONS.  Same role as `STRICT_PROTO` in
  -- `seq_desc_fetch`: the bench drives harder than the real system on
  -- purpose, so these are switchable rather than unconditional.
  -- ====================================================================
  gstrict : if STRICT generate
    chk : process(clk) is
    begin
      if rising_edge(clk) then
        if rst = '0' then
          assert not (xw_we = '1' and (running = '1' or d_busy = '1'))
            report "fk33_seam: a host region write landed while a token was "
                 & "in flight.  The region lock does not police this port."
            severity error;
          assert not (go_r = '1' and st_err = '1')
            report "fk33_seam: GO raised with the error bit set."
            severity error;
        end if;
      end if;
    end process;
  end generate;

end architecture;
