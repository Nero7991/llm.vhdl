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
--   0x04 STATUS : read  bit0=done (run finished), bit1=busy.
--   0x08 COUNT  : read  number of tokens emitted so far (0..NGEN).
--   0x0C CFG    : read  {NGEN[31:16], MAXPOS[15:0]}.
--   0x20 ID     : read  0x6C6C6D31  ("llm1").
--   0x40..      : read  TOKEN[i] = i-th generated token id (i=0..MAXTOK-1),
--                 word index 16+i (byte 0x40 + 4*i).
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
    generic map(MAXPOS => MAXPOS, NGEN => NGEN, ROM_DIR => ROM_DIR)
    port map(clk => s_axi_aclk, rst => eng_rst, start => eng_start,
             token_out => eng_token, pos_out => eng_pos,
             token_valid => eng_tvalid, run_done => eng_rundone);

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
            when others => null;
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
          if ridx >= 16 and ridx < 16+MAXTOK then
            rdata_r <= tok_buf(ridx-16);                                   -- TOKEN[i]
          else
            case ridx is
              when 1 => rdata_r <= (31 downto 2 => '0') & busy & status_done;   -- STATUS
              when 2 => rdata_r <= std_logic_vector(to_unsigned(tok_count, 32));-- COUNT
              when 3 => rdata_r <= std_logic_vector(to_unsigned(NGEN, 16)) &
                                   std_logic_vector(to_unsigned(MAXPOS, 16));   -- CFG
              when 8 => rdata_r <= x"6C6C6D31";                                 -- ID "llm1"
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
