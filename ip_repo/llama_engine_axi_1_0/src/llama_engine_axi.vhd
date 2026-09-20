-- rtl/llama_engine_axi.vhd -- AXI4-Lite wrapper around engine_shared.
--
-- engine_shared is the SHARED-datapath stories260K transformer (bit-exact vs the
-- C oracle, tb_engine_shared 24/24).  It is AUTONOMOUS: on START it teacher-forces
-- the baked prompt (ids 1,403,407,261,378 = "Once upon a time") then greedily
-- generates to NGEN positions, emitting each next-token on `token_valid` with its
-- `pos`.  This wrapper resets+starts the engine on a CTRL write, captures the
-- streamed tokens into a small readback buffer, and exposes status.  The PS thus:
--   1. write CTRL bit0=1  -> reset engine, begin a run (STATUS.busy=1)
--   2. poll STATUS until bit0(done)=1
--   3. read COUNT, then TOKEN[0..COUNT-1]  -> the generated token ids
--
-- Register map (C_S_AXI_ADDR_WIDTH=8, word-addressed reg = addr[7:2]):
--   0x00 CTRL   : write bit0=1 -> START (reset + run).
--                 read  L1_SUM  = sum_l[31:0] consumed by the hd0/t1 divide
--                       (CTRL is write-only, so its read slot carries a probe).
--   0x04 STATUS : read  bit0=done (run finished), bit1=busy.
--   0x08 COUNT  : read  number of tokens emitted so far (0..NGEN).
--   0x0C CFG    : read  {NGEN[31:16], MAXPOS[15:0]}.
--   0x10 DBG_POS: write which position the debug taps capture (-1 = none).
--                 read  L1_NSD_H = ns_dout[63:32] at the hd0/t1 divide
--                       (DBG_POS is write-only, so its read slot carries a probe).
--   0x14/18/1C  : read  x after layers 1/2/3 (dbgpack).
--   0x20 ID     : read  0x6C6C6D31  ("llm1").
--   0x24 AMAX_L : read  attention amax_s[31:0]   (sticky |xb_acc| max, L0/dbg_pos)
--   0x28 AMAX_H : read  attention amax_s[63:32]
--   0x2C IDX    : read  {nmax lane[15:8], amax lane[7:0]}; head = lane/HEAD_SIZE
--   0x30 NMAX_L : read  max|num_s| over all 64 lanes [31:0]
--   0x34 NMAX_H : read  max|num_s| over all 64 lanes [63:32]
--   0x38/0x3C   : read  0 (SPARE -- were the hd0/t1 lane qmag probes; attention is
--                 solved on silicon so the lane-1 divide probes are retired).
--   0x40..0x9C  : read  TOKEN[i] = i-th generated token id (i=0..NGEN-1),
--                 word index 16+i (byte 0x40 + 4*i).
--   0xA0..0xB8  : read  INTRA-LAYER-0 STAGE BISECT taps, in DATAFLOW ORDER, all in
--                 the standard dbgpack format {nz[24], exp[23:16], m0[15:0]}, all
--                 for cur_layer=0 at position dbg_pos:
--                 0xA0 WO matmul out        (matmul_rt, mat_sel=WO)
--                 0xA4 residual-1 out       (residual.vhd: x + WO)
--                 0xA8 FFN rmsnorm out      (rmsnorm.vhd, RMS_FFN)
--                 0xAC W1 matmul out        (matmul_rt, mat_sel=W1, HIDDEN-wide)
--                 0xB0 W3 matmul out        (matmul_rt, mat_sel=W3, HIDDEN-wide)
--                 0xB4 bfp_pack out         (swiglu -> vec_mem -> bfp_pack)
--                 0xB8 W2 matmul out        (matmul_rt, mat_sel=W2)
--                 (REPLACES the running-max-quotient block: the attention divide is
--                  fixed by divider_rs and reads bit-exact on silicon.)
--   0xBC        : read  0 (SPARE)
--   0xC0..0xD8  : read  residual-stream / rmsnorm / attention debug taps.
--   0xDC/0xE0   : read  0 (SPARE -- were the hd0/t1 DIVIDEND probes).
--   0xE4..0xF8  : read  rmsnorm exps / attention sc/sum/num taps.
--   0xFC L1_NSD_L : read  hd0/t1 ns_dout[31:0]
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity llama_engine_axi is
  generic(
    MAXPOS : integer := 24;
    NGEN   : integer := 24;
    MAXTOK : integer := 32;   -- token readback buffer depth (>= NGEN)
    -- Weight-ROM directory forwarded to engine_shared; the design_1 module-ref
    -- overrides this to an absolute path so the .mem files resolve at impl synth.
    ROM_DIR : string := "../mem/rom/";
    C_S_AXI_DATA_WIDTH : integer := 32;
    C_S_AXI_ADDR_WIDTH : integer := 8);
  port(
    s_axi_aclk    : in  std_logic;
    s_axi_aresetn : in  std_logic;
    s_axi_awaddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_awprot  : in  std_logic_vector(2 downto 0);
    s_axi_awvalid : in  std_logic;
    s_axi_awready : out std_logic;
    s_axi_wdata   : in  std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_wstrb   : in  std_logic_vector((C_S_AXI_DATA_WIDTH/8)-1 downto 0);
    s_axi_wvalid  : in  std_logic;
    s_axi_wready  : out std_logic;
    s_axi_bresp   : out std_logic_vector(1 downto 0);
    s_axi_bvalid  : out std_logic;
    s_axi_bready  : in  std_logic;
    s_axi_araddr  : in  std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);
    s_axi_arprot  : in  std_logic_vector(2 downto 0);
    s_axi_arvalid : in  std_logic;
    s_axi_arready : out std_logic;
    s_axi_rdata   : out std_logic_vector(C_S_AXI_DATA_WIDTH-1 downto 0);
    s_axi_rresp   : out std_logic_vector(1 downto 0);
    s_axi_rvalid  : out std_logic;
    s_axi_rready  : in  std_logic);
end;

architecture rtl of llama_engine_axi is
  -- AXI handshake
  signal awready,wready,bvalid,arready,rvalid : std_logic := '0';
  signal rdata_r : std_logic_vector(31 downto 0) := (others=>'0');
  signal wr_addr : std_logic_vector(C_S_AXI_ADDR_WIDTH-1 downto 0);

  -- engine control / status
  signal start_pulse : std_logic := '0';   -- CTRL write strobe
  signal eng_rst     : std_logic := '1';
  signal eng_start   : std_logic := '0';
  signal eng_token   : integer;
  signal eng_pos     : integer;
  signal eng_tvalid  : std_logic;
  signal eng_rundone : std_logic;
  signal rst_cnt     : integer range 0 to 7 := 0;   -- engine-reset hold on START
  signal pend_start  : std_logic := '0';
  signal busy        : std_logic := '0';
  signal status_done : std_logic := '0';

  -- debug taps (from engine_shared, for the position dbg_pos_reg)
  signal dbg_pos_reg : integer := -1;

  -- ---- RUNTIME PROMPT -------------------------------------------------------
  -- PROMPT[i] is written at word 40+i (0xA0 + 4i), the length at 0x14.  Both
  -- reset to the prompt the engine used to bake in ("<BOS> Once upon a time"),
  -- so a bare START with nothing written still produces the golden story -- that
  -- keeps the on-hardware golden check meaningful as a regression test.
  -- Only the low 16 bits of each write are kept: ids are 0..VOCAB-1.
  constant PROMPT_WORD0 : integer := 40;                 -- 0xA0
  constant DEF_PROMPT   : std_logic_vector(MAXPOS*16-1 downto 0) :=
      x"0000000000000000000000000000000000000000000000000000000000000000000000000000" &
      x"017A0105019701930001";
  signal prompt_reg : std_logic_vector(MAXPOS*16-1 downto 0) := DEF_PROMPT;
  signal prompt_len_reg : integer range 1 to MAXPOS := 5;
  -- engine_shared's `prompt_len` is an unconstrained integer; GHDL 6.0.0
  -- refuses the direct association with the constrained register above
  -- (2026-09-19), so this copy is what the port sees.  A wire.
  signal prompt_len_i   : integer := 5;

  -- one token out of the packed prompt register (ids are unsigned 0..VOCAB-1)
  impure function prompt_word(i : integer) return std_logic_vector is
  begin
    return prompt_reg((i+1)*16-1 downto i*16);
  end function;
  signal e_emb_nz, e_l0_nz, e_l1_nz, e_l2_nz, e_l3_nz, e_l4_nz, e_fin_nz, e_rms_nz, e_att_nz : std_logic;
  signal e_emb_e, e_l0_e, e_l1_e, e_l2_e, e_l3_e, e_l4_e, e_fin_e, e_rms_e, e_att_e, e_stok : integer;
  signal e_att_sc, e_att_sum, e_att_num : integer;   -- attention-internal taps
  signal e_emb_m, e_l0_m, e_l1_m, e_l2_m, e_l3_m, e_l4_m, e_fin_m, e_rms_m, e_att_m : std_logic_vector(15 downto 0);
  -- intra-layer-0 stage bisect taps (WO / res1 / ffn-rms / W1 / W3 / bfp_pack / W2)
  signal e_wo_nz, e_r1_nz, e_rf_nz, e_w1_nz, e_w3_nz, e_hb_nz, e_w2_nz : std_logic;
  signal e_wo_e,  e_r1_e,  e_rf_e,  e_w1_e,  e_w3_e,  e_hb_e,  e_w2_e  : integer;
  signal e_wo_m,  e_r1_m,  e_rf_m,  e_w1_m,  e_w3_m,  e_hb_m,  e_w2_m  : std_logic_vector(15 downto 0);
  signal e_rxchk, e_rwchk, e_rxe, e_rwe : integer;
  signal e_rw0 : std_logic_vector(15 downto 0);
  -- per-head / per-lane attention probes (oversized-lane hunt)
  signal e_att_sums : std_logic_vector(8*32-1 downto 0);
  signal e_amax_l, e_amax_h, e_nmax_l, e_nmax_h : std_logic_vector(31 downto 0);
  signal e_att_idx : std_logic_vector(15 downto 0);
  -- failing-division capture (attention_ml S_WDIV)
  signal e_cd_qmag_l, e_cd_qmag_h, e_cd_nmag_l, e_cd_nmag_h : std_logic_vector(31 downto 0);
  signal e_cd_nsd_l, e_cd_nsd_h, e_cd_sum, e_cd_meta        : std_logic_vector(31 downto 0);
  signal e_l1_qmag_l, e_l1_qmag_h, e_l1_nsd_l, e_l1_nsd_h, e_l1_sum : std_logic_vector(31 downto 0);
  -- hd0/t1 DIVIDEND + running-max-quotient capture (attention_ml S_WDIV)
  signal e_l1_nmag_l, e_l1_nmag_h : std_logic_vector(31 downto 0);
  signal e_qx_qmag_l, e_qx_qmag_h, e_qx_nmag_l, e_qx_nmag_h : std_logic_vector(31 downto 0);
  signal e_qx_nsd_l, e_qx_nsd_h, e_qx_sum, e_qx_meta        : std_logic_vector(31 downto 0);
  -- shared-rmsnorm internal bisect (FFN = failing call, ATT = good control)
  signal e_rf_xchk, e_rf_wchk, e_rf_inv                     : std_logic_vector(31 downto 0);
  signal e_rf_ssq_l, e_rf_ssq_h, e_rf_msq_l, e_rf_msq_h     : std_logic_vector(31 downto 0);
  signal e_rf_mrw_l, e_rf_mrw_h                             : std_logic_vector(31 downto 0);
  signal e_ra_xchk, e_ra_ssq_l, e_ra_inv                    : std_logic_vector(31 downto 0);
  signal e_rf_sh                                            : integer;
  -- whole-vector dataflow signatures (unit output vs staging register)
  signal e_vc_emb, e_vc_xcur, e_vc_wo, e_vc_woreg           : std_logic_vector(31 downto 0);
  signal e_vc_res1, e_vc_xm, e_vc_rmsx, e_vc_rmso           : std_logic_vector(31 downto 0);
  signal e_vc_w1, e_vc_w3                                   : std_logic_vector(31 downto 0);

  -- pack a debug point {nz, exp(int8), m0(int16)} into one 32-bit reg.
  function dbgpack(nz : std_logic; e : integer; m : std_logic_vector(15 downto 0))
    return std_logic_vector is
  begin
    return (31 downto 25 => '0') & nz & std_logic_vector(to_signed(e, 8)) & m;
  end function;

  -- token readback buffer
  type tokbuf_t is array(0 to MAXTOK-1) of std_logic_vector(31 downto 0);
  signal tok_buf   : tokbuf_t := (others => (others => '0'));
  signal tok_count : integer range 0 to MAXTOK := 0;
begin
  s_axi_awready<=awready; s_axi_wready<=wready; s_axi_bvalid<=bvalid; s_axi_bresp<="00";
  s_axi_arready<=arready; s_axi_rvalid<=rvalid; s_axi_rresp<="00"; s_axi_rdata<=rdata_r;

  -- Engine held in reset while rst_cnt is nonzero (and by the AXI reset).
  eng_rst <= '1' when (s_axi_aresetn='0' or rst_cnt /= 0) else '0';

  u_engine: entity work.engine_shared
    -- DEBUG_TAPS off: the silicon bring-up taps have done their job (the engine
    -- is bit-exact), and dropping them frees both LUT (helping timing) and the
    -- 0xA0.. address slots now used by the writable prompt.  Re-enable for debug.
    generic map(MAXPOS => MAXPOS, NGEN => NGEN, ROM_DIR => ROM_DIR, DEBUG_TAPS => false)
    port map(clk => s_axi_aclk, rst => eng_rst, start => eng_start,
             token_out => eng_token, pos_out => eng_pos,
             token_valid => eng_tvalid, run_done => eng_rundone,
             dbg_pos => dbg_pos_reg,
             prompt_mant => prompt_reg, prompt_len => prompt_len_i,
             dbg_emb_nz => e_emb_nz, dbg_emb_e => e_emb_e, dbg_emb_m => e_emb_m,
             dbg_l0_nz  => e_l0_nz,  dbg_l0_e  => e_l0_e,  dbg_l0_m  => e_l0_m,
             dbg_l1_nz  => e_l1_nz,  dbg_l1_e  => e_l1_e,  dbg_l1_m  => e_l1_m,
             dbg_l2_nz  => e_l2_nz,  dbg_l2_e  => e_l2_e,  dbg_l2_m  => e_l2_m,
             dbg_l3_nz  => e_l3_nz,  dbg_l3_e  => e_l3_e,  dbg_l3_m  => e_l3_m,
             dbg_l4_nz  => e_l4_nz,  dbg_l4_e  => e_l4_e,  dbg_l4_m  => e_l4_m,
             dbg_fin_nz => e_fin_nz, dbg_fin_e => e_fin_e, dbg_fin_m => e_fin_m,
             dbg_rms_nz => e_rms_nz, dbg_rms_e => e_rms_e, dbg_rms_m => e_rms_m,
             dbg_att_nz => e_att_nz, dbg_att_e => e_att_e, dbg_att_m => e_att_m,
             dbg_wo_nz => e_wo_nz, dbg_wo_e => e_wo_e, dbg_wo_m => e_wo_m,
             dbg_r1_nz => e_r1_nz, dbg_r1_e => e_r1_e, dbg_r1_m => e_r1_m,
             dbg_rf_nz => e_rf_nz, dbg_rf_e => e_rf_e, dbg_rf_m => e_rf_m,
             dbg_w1_nz => e_w1_nz, dbg_w1_e => e_w1_e, dbg_w1_m => e_w1_m,
             dbg_w3_nz => e_w3_nz, dbg_w3_e => e_w3_e, dbg_w3_m => e_w3_m,
             dbg_hb_nz => e_hb_nz, dbg_hb_e => e_hb_e, dbg_hb_m => e_hb_m,
             dbg_w2_nz => e_w2_nz, dbg_w2_e => e_w2_e, dbg_w2_m => e_w2_m,
             dbg_rxchk => e_rxchk, dbg_rwchk => e_rwchk, dbg_rxe => e_rxe, dbg_rwe => e_rwe, dbg_rw0 => e_rw0,
             dbg_samptok => e_stok,
             dbg_att_sc => e_att_sc, dbg_att_sum => e_att_sum, dbg_att_num => e_att_num,
             dbg_att_sums => e_att_sums,
             dbg_att_amax_l => e_amax_l, dbg_att_amax_h => e_amax_h,
             dbg_att_nmax_l => e_nmax_l, dbg_att_nmax_h => e_nmax_h,
             dbg_att_idx => e_att_idx,
             dbg_cd_qmag_l => e_cd_qmag_l, dbg_cd_qmag_h => e_cd_qmag_h,
             dbg_cd_nmag_l => e_cd_nmag_l, dbg_cd_nmag_h => e_cd_nmag_h,
             dbg_cd_nsd_l  => e_cd_nsd_l,  dbg_cd_nsd_h  => e_cd_nsd_h,
             dbg_cd_sum    => e_cd_sum,    dbg_cd_meta   => e_cd_meta,
             dbg_l1_qmag_l => e_l1_qmag_l, dbg_l1_qmag_h => e_l1_qmag_h,
             dbg_l1_nsd_l  => e_l1_nsd_l,  dbg_l1_nsd_h  => e_l1_nsd_h,
             dbg_l1_sum    => e_l1_sum,
             dbg_l1_nmag_l => e_l1_nmag_l, dbg_l1_nmag_h => e_l1_nmag_h,
             dbg_qx_qmag_l => e_qx_qmag_l, dbg_qx_qmag_h => e_qx_qmag_h,
             dbg_qx_nmag_l => e_qx_nmag_l, dbg_qx_nmag_h => e_qx_nmag_h,
             dbg_qx_nsd_l  => e_qx_nsd_l,  dbg_qx_nsd_h  => e_qx_nsd_h,
             dbg_qx_sum    => e_qx_sum,    dbg_qx_meta   => e_qx_meta,
             dbg_rf_xchk  => e_rf_xchk,  dbg_rf_wchk  => e_rf_wchk,
             dbg_rf_ssq_l => e_rf_ssq_l, dbg_rf_ssq_h => e_rf_ssq_h,
             dbg_rf_msq_l => e_rf_msq_l, dbg_rf_msq_h => e_rf_msq_h,
             dbg_rf_inv   => e_rf_inv,
             dbg_rf_mrw_l => e_rf_mrw_l, dbg_rf_mrw_h => e_rf_mrw_h,
             dbg_rf_sh    => e_rf_sh,
             dbg_ra_xchk  => e_ra_xchk,  dbg_ra_ssq_l => e_ra_ssq_l,
             dbg_ra_inv   => e_ra_inv,
             dbg_vc_emb   => e_vc_emb,   dbg_vc_xcur  => e_vc_xcur,
             dbg_vc_wo    => e_vc_wo,    dbg_vc_woreg => e_vc_woreg,
             dbg_vc_res1  => e_vc_res1,  dbg_vc_xm    => e_vc_xm,
             dbg_vc_rmsx  => e_vc_rmsx,  dbg_vc_rmso  => e_vc_rmso,
             dbg_vc_w1    => e_vc_w1,    dbg_vc_w3    => e_vc_w3);
  prompt_len_i <= prompt_len_reg;


  -- AXI write channel + CTRL decode.
  process(s_axi_aclk)
  begin
    if rising_edge(s_axi_aclk) then
      start_pulse <= '0';
      if s_axi_aresetn='0' then
        awready<='0'; wready<='0'; bvalid<='0';
      else
        if awready='0' and s_axi_awvalid='1' and s_axi_wvalid='1' then
          awready<='1'; wready<='1'; wr_addr<=s_axi_awaddr;
        else awready<='0'; wready<='0'; end if;
        if awready='1' and wready='1' then
          case to_integer(unsigned(wr_addr(7 downto 2))) is
            when 0 => if s_axi_wdata(0)='1' then start_pulse<='1'; end if;  -- CTRL START
            when 4 => dbg_pos_reg <= to_integer(signed(s_axi_wdata));        -- DBG_POS
            when 5 =>                                                        -- 0x14 PROMPT_LEN
              -- clamp into 1..MAXPOS so a bad write cannot wedge the FSM
              if to_integer(unsigned(s_axi_wdata)) < 1 then
                prompt_len_reg <= 1;
              elsif to_integer(unsigned(s_axi_wdata)) > MAXPOS then
                prompt_len_reg <= MAXPOS;
              else
                prompt_len_reg <= to_integer(unsigned(s_axi_wdata));
              end if;
            when others =>
              -- PROMPT[i] at word 40+i (0xA0 + 4i), i = 0 .. MAXPOS-1
              if to_integer(unsigned(wr_addr(7 downto 2))) >= PROMPT_WORD0 and
                 to_integer(unsigned(wr_addr(7 downto 2))) <  PROMPT_WORD0 + MAXPOS then
                for i in 0 to MAXPOS-1 loop
                  if to_integer(unsigned(wr_addr(7 downto 2))) = PROMPT_WORD0 + i then
                    prompt_reg((i+1)*16-1 downto i*16) <= s_axi_wdata(15 downto 0);
                  end if;
                end loop;
              end if;
          end case;
          bvalid<='1';
        elsif bvalid='1' and s_axi_bready='1' then
          bvalid<='0';
        end if;
      end if;
    end if;
  end process;

  -- Engine start sequencer + token capture + status.
  process(s_axi_aclk)
    variable done_l : std_logic := '0';
  begin
    if rising_edge(s_axi_aclk) then
      eng_start <= '0';
      if s_axi_aresetn='0' then
        rst_cnt<=0; pend_start<='0'; busy<='0'; tok_count<=0; done_l:='0';
      else
        -- START: hold the engine in reset a few cycles, then pulse start as the
        -- reset releases, and re-arm the token capture for the new run.
        if start_pulse='1' then
          rst_cnt    <= 4;
          pend_start <= '1';
          busy       <= '1';
          tok_count  <= 0;
          done_l     := '0';
        elsif rst_cnt /= 0 then
          rst_cnt <= rst_cnt - 1;
          if rst_cnt = 1 and pend_start='1' then
            eng_start  <= '1';    -- fires the cycle eng_rst deasserts
            pend_start <= '0';
          end if;
        end if;

        -- Capture each streamed token in emission (position) order.
        if eng_tvalid='1' and tok_count < MAXTOK then
          tok_buf(tok_count) <= std_logic_vector(to_signed(eng_token, 32));
          tok_count <= tok_count + 1;
        end if;

        -- Completion latch (set on run_done, cleared on START).
        if eng_rundone='1' then busy<='0'; done_l:='1'; end if;
      end if;
      status_done <= done_l;
    end if;
  end process;

  -- AXI read channel.
  process(s_axi_aclk)
    variable ridx : integer;
  begin
    if rising_edge(s_axi_aclk) then
      if s_axi_aresetn='0' then arready<='0'; rvalid<='0';
      else
        if arready='0' and s_axi_arvalid='1' then
          arready<='1';
          ridx := to_integer(unsigned(s_axi_araddr(7 downto 2)));
          -- TOKEN[] window narrowed from MAXTOK(32) to NGEN(24) words so the
          -- never-written tail (words 40..47 = 0xA0..0xBC) is FREE for probe
          -- registers.  The 8-bit AXI address space only decodes words 0..63.
          if ridx >= 16 and ridx < 16+NGEN then
            rdata_r <= tok_buf(ridx-16);                                   -- TOKEN[i]
          elsif ridx >= PROMPT_WORD0 and ridx < PROMPT_WORD0 + MAXPOS then
            -- runtime PROMPT readback (written at the same 0xA0+4i addresses).
            -- Everything else that used to live in this window was silicon
            -- bring-up debug taps; DEBUG_TAPS is off now, so they are gone rather
            -- than returning stale garbage.  Restore from git (a5b9888) if the
            -- engine ever needs bisecting again.
            rdata_r <= (31 downto 16 => '0') & prompt_word(ridx - PROMPT_WORD0);
          else
            case ridx is
              when 1 => rdata_r <= (31 downto 2 => '0') & busy & status_done;   -- STATUS
              when 2 => rdata_r <= std_logic_vector(to_unsigned(tok_count, 32));-- COUNT
              when 3 => rdata_r <= std_logic_vector(to_unsigned(NGEN, 16)) &
                                   std_logic_vector(to_unsigned(MAXPOS, 16));   -- CFG
              when 5 => rdata_r <= std_logic_vector(to_unsigned(prompt_len_reg, 32)); -- PROMPT_LEN
              when 8 => rdata_r <= x"6C6C6D31";                                 -- ID "llm1"
              -- 0x00 CTRL and 0x10 DBG_POS are write-only; everything that used to
              -- sit in the other read slots was silicon bring-up debug taps.
              -- DEBUG_TAPS is off now, so those reads are gone rather than
              -- returning stale garbage; restore from git (a5b9888) if the engine
              -- ever needs bisecting again.
              when others => rdata_r <= (others=>'0');
            end case;
          end if;
        else arready<='0'; end if;
        if arready='1' then rvalid<='1';
        elsif rvalid='1' and s_axi_rready='1' then rvalid<='0'; end if;
      end if;
    end if;
  end process;
end;
