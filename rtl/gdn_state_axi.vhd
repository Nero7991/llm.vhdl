-- rtl/gdn_state_axi.vhd -- moves ONE GDN layer's recurrent state between HBM
-- and the on-chip `rtl/gdn_state_mem.vhd`.
--
-- WHY THIS EXISTS.  MEASURED 2026-09-02: the recurrent state for all 24 GDN
-- layers at the 9B shape is 201,326,592 bits = 24.0 MB, against 14.2 MB of
-- BRAM plus URAM on the whole `xcvu33p`.  It cannot be resident.  ONE layer is
-- 8,388,608 bits = 1.0 MB and fits in 32 URAM288, so the card holds one layer
-- and moves it per job.  See
-- docs/debugging/2026-09-02_gdn-state-does-not-fit-on-chip.md.
--
-- THE ADDRESS MAP IS NOT INVENTED HERE, AND MUST NOT BE.  `tools/hbm_map.py`
-- already derives, and `tools/pack_model_fk33.py` already reserves in the
-- manifest, `gdn_state_mant_bytes_per_layer = 1048576` and
-- `gdn_state_exp_bytes_per_layer = 4096`, stride 1052672, 24 layers,
-- 25,264,128 bytes total, with `server/fk33_manifest.c` enforcing
-- `gdn_state_base >= weights_end`.  `state_base` is an INPUT for exactly that
-- reason: this module is told where the arena is and never computes it.  That
-- address space has already had one silent collision between two allocators
-- that could not see each other, and the symptom was a WRONG TOKEN.
--
-- WHY BULK DMA AND NOT A CACHE.  `gdn_block`'s `st_rdata` is a registered read
-- ONE cycle after the address (rtl/gdn_block.vhd:1157-1174).  HBM latency is
-- two orders of magnitude larger than that, so no amount of prefetching lets
-- the unit read HBM directly.  The whole layer is brought in before `start`
-- and written back after `busy` falls.  That is why this is a DMA and why
-- `attn_kv_axi` -- which IS a cache, because attention reads arbitrary past
-- positions -- is a template for the AXI conventions here and not for the
-- structure.
--
-- AXI3, SO `awlen`/`arlen` ARE 4 BITS AND 16 BEATS IS THE HARD CAP.  The FK33
-- HBM slave is AXI3; a module's own assert bounds what THAT module permits and
-- says nothing about what the slave accepts.  `MAXB` defaults to 16 and the
-- refusal below is an out-of-range constant, not an assert, because Vivado
-- ignores `assert ... severity failure` in synthesis.
--
-- OUTSTANDING BURSTS ARE NOT AN OPTIMISATION HERE, THEY ARE THE DIFFERENCE
-- BETWEEN 31 AND 127 TOKENS PER SECOND.  DERIVED at the 9B shape: one layer is
-- 32,768 beats of 256 bits, i.e. 2,048 bursts of 16.  Serialised at an assumed
-- 50-cycle HBM read latency that is 2048*(16+50) = 135k cycles, 0.68 ms at
-- 200 MHz, and 24 layers x (load + store) puts a 32 ms/token floor under the
-- model from this transfer alone.  With MAXOUT in flight the latency hides
-- behind the data and the same traffic is ~32,768 cycles, 0.16 ms, i.e.
-- 7.9 ms/token.  **The 50-cycle latency is an ESTIMATE and has not been
-- measured on this card**; the ratio is what matters and it does not depend
-- on the exact figure.
--
-- STATUS: the mantissa path only.  The 4,096 bytes of per-layer state
-- EXPONENTS (`semem` in llama_top) are declared in the arena and are NOT moved
-- by this module yet, and neither is the conv tap history, which has no arena
-- reservation at all.  Both are named in the write-up's open list.  This
-- module REFUSES to claim it moved them: `exp_done` does not exist.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.util_pkg.all;

entity gdn_state_axi is
  generic(
    -- geometry, matching rtl/gdn_state_mem.vhd and rtl/gdn_block.vhd
    VAL_HEADS   : positive := 32;
    DIM         : positive := 128;
    RECUR_LANES : positive := 4;
    LAYERS      : positive := 24;

    -- WORD SHAPE, DEFAULTED TO THE MANTISSA STORE SO NOTHING EXISTING MOVES.
    -- These exist so this one mover can also carry the per-layer state
    -- EXPONENTS, which are `VAL_HEADS x DIM` bytes -- 4,096 at the 9B shape,
    -- exactly `gdn_state_exp_bytes_per_layer` in the manifest -- rather than
    -- needing a second module and, more to the point, a second pair of AXI
    -- masters.  **HBM master count is a real constraint on this card**, and
    -- spending a read and a write master on 4 KB per layer is the wrong
    -- trade when a mux costs a few LUTs.
    --   mantissas:  WORD_BITS = RECUR_LANES*16, N_GRP = DIM/RECUR_LANES
    --   exponents:  WORD_BITS = 8,              N_GRP = 1
    -- Both derive their own BEATS, BURSTS and byte count from these, and the
    -- `bad_mant_bytes_vs_shape` refusal below then checks each against the
    -- arena figure it was given.  A defaulted generic that reproduces the
    -- previous behaviour exactly is what makes this safe to add to a module
    -- that already has a passing bench: if the bench still passes, the
    -- generalisation is behaviour-preserving.
    WORD_BITS   : positive := RECUR_LANES * 16;
    N_GRP       : positive := DIM / RECUR_LANES;

    -- the arena, from tools/hbm_map.py::arena_sizes().  DEFAULTS ARE THE 9B
    -- FIGURES AND ARE STILL ONLY DEFAULTS: the caller passes the manifest's.
    LAYER_STRIDE : positive := 1052672;   -- gdn_state_bytes_per_layer
    MANT_BYTES   : positive := 1048576;   -- gdn_state_mant_bytes_per_layer

    -- AXI
    AXI_DW : positive := 256;   -- FK33 HBM SAXI data width
    ADDR_W : positive := 33;    -- 8 GiB
    MAXB   : positive := 16;    -- AXI3: ARLEN is 4 bits.  16 is the CAP.
    MAXOUT : positive := 4      -- bursts in flight
  );
  port(
    clk : in std_logic;
    rst : in std_logic;

    -- ---- job control ----------------------------------------------------
    -- Both are ONE-CYCLE pulses and are mutually exclusive; `busy` covers the
    -- whole transfer and `done` is a one-cycle pulse at the end of it.
    load_start : in  std_logic;
    save_start : in  std_logic;
    layer      : in  integer range 0 to LAYERS-1;
    state_base : in  std_logic_vector(ADDR_W-1 downto 0);
    busy       : out std_logic;
    done       : out std_logic;
    err        : out std_logic;   -- sticky: a non-OKAY response, or overrun

    -- ---- the on-chip store.  Driven ONLY while `busy`. -------------------
    -- The caller muxes these against `gdn_block`'s st_* ports; this module
    -- deliberately does not, because the mux belongs with whoever owns both.
    --
    -- ADDRESSED AS (head, col, grp) AND NOT AS A FLAT WORD INDEX, because
    -- that is `gdn_state_mem`'s port shape and `gdn_block`'s, so all three
    -- agree and the mux is a plain 2:1 with no arithmetic in it.  A DMA that
    -- emitted a flat index would push the decomposition into the mux, which
    -- is where an integration error would be invisible: the first version of
    -- this module did exactly that, the bench wired the flat address to
    -- nothing, and every load read back as zero.
    --
    -- The decomposition is exact rather than conventional: gdn_state_mem's
    -- own index is `(head*DIM + col)*NBR + grp`, so flat transfer order IS
    -- linear memory order and the layer streams to HBM contiguously.
    m_w_en   : out std_logic;
    m_w_head : out natural range 0 to VAL_HEADS-1;
    m_w_col  : out natural range 0 to DIM-1;
    m_w_grp  : out natural range 0 to N_GRP-1;
    m_w_data : out std_logic_vector(WORD_BITS-1 downto 0);
    m_r_en   : out std_logic;
    m_r_head : out natural range 0 to VAL_HEADS-1;
    m_r_col  : out natural range 0 to DIM-1;
    m_r_grp  : out natural range 0 to N_GRP-1;
    m_r_data : in  std_logic_vector(WORD_BITS-1 downto 0);

    -- ---- the read master -------------------------------------------------
    r_arvalid : out std_logic;
    r_arready : in  std_logic;
    r_araddr  : out std_logic_vector(ADDR_W-1 downto 0);
    r_arlen   : out std_logic_vector(7 downto 0);
    r_arsize  : out std_logic_vector(2 downto 0);
    r_arburst : out std_logic_vector(1 downto 0);
    r_rvalid  : in  std_logic;
    r_rready  : out std_logic;
    r_rdata   : in  std_logic_vector(AXI_DW-1 downto 0);
    r_rlast   : in  std_logic;
    r_rresp   : in  std_logic_vector(1 downto 0);

    -- ---- the write master ------------------------------------------------
    w_awvalid : out std_logic;
    w_awready : in  std_logic;
    w_awaddr  : out std_logic_vector(ADDR_W-1 downto 0);
    w_awlen   : out std_logic_vector(7 downto 0);
    w_awsize  : out std_logic_vector(2 downto 0);
    w_awburst : out std_logic_vector(1 downto 0);
    w_wvalid  : out std_logic;
    w_wready  : in  std_logic;
    w_wdata   : out std_logic_vector(AXI_DW-1 downto 0);
    w_wstrb   : out std_logic_vector(AXI_DW/8-1 downto 0);
    w_wlast   : out std_logic;
    w_bvalid  : in  std_logic;
    w_bready  : out std_logic;
    w_bresp   : in  std_logic_vector(1 downto 0)
  );
end entity;

architecture rtl of gdn_state_axi is
  constant NBR    : positive := N_GRP;
  constant WORDS  : positive := VAL_HEADS * DIM * NBR;
  constant WBITS  : positive := WORD_BITS;
  constant WPB    : positive := AXI_DW / WBITS;      -- store words per beat
  constant BEATS  : positive := WORDS / WPB;         -- beats in one layer
  -- NOT `positive`.  A geometry with fewer beats than MAXB gives 0 here, and
  -- as a `positive` that is a bare "bound check failure at line 155" with no
  -- name attached -- which is what the parameter sweep actually hit.  Declared
  -- `natural` so the NAMED refusal below is the thing that fires.
  constant BURSTS : natural := BEATS / MAXB;
  constant BPB    : positive := AXI_DW / 8;          -- bytes per beat

  -- ---- REFUSALS THAT RUN DURING ELABORATION ---------------------------
  -- Every one is an out-of-range `natural`, not an assert: Vivado silently
  -- ignores `assert ... severity failure` in synthesis, and a constant that
  -- goes negative is evaluated by both tools.  The NAME is the diagnostic.
  --
  -- AXI3 caps a burst at 16 beats.  A generic above that produces a legal
  -- ARLEN encoding for a slave that will not honour it, which is the worst
  -- kind of wrong: it looks like a working transfer.
  constant bad_maxb_over_axi3_cap : natural := 16 - MAXB;
  -- The store word must tile the AXI beat exactly.  A partial word would need
  -- a shifter this module does not have.
  constant bad_axi_dw_not_multiple_of_word : natural := AXI_DW - WPB*WBITS;
  -- The layer must tile into whole bursts.  A remainder would need a short
  -- final burst, which is legal AXI and is simply not implemented here.
  constant bad_beats_not_multiple_of_maxb : natural := BEATS - BURSTS*MAXB;
  -- The arena's per-layer mantissa reservation must match what we move.  This
  -- is the check that catches a manifest and an RTL shape drifting apart, and
  -- it is the one that would otherwise show up as a wrong token.
  constant bad_mant_bytes_vs_shape : natural := MANT_BYTES - BEATS*BPB;
  -- A layer cannot overlap its neighbour.
  constant bad_stride_below_mant : natural := LAYER_STRIDE - MANT_BYTES;
  -- THE PER-LAYER STRIDE MUST BE A WHOLE NUMBER OF BEATS.  A stride that is
  -- not beat-aligned makes every ODD layer start mid-beat, and since the
  -- address is only ever formed as `base + layer*stride` the misalignment is
  -- silent: layers 0 and 1 transfer correctly and layer 2 lands a beat short.
  -- MEASURED by the parameter sweep, which is the only reason this refusal
  -- exists: at AXI_DW=256 a bench stride of MANT_BYTES+16 is 528 bytes
  -- against a 32-byte beat, and exactly one layer of 256 checks failed while
  -- the other two passed.  The shipping 9B numbers ARE aligned
  -- (1,052,672 / 32 = 32,896) so this never fires in the real configuration,
  -- which is precisely why it needed a sweep to find.
  constant bad_stride_not_beat_aligned : natural := 0 - (LAYER_STRIDE mod BPB);
  -- A geometry with fewer beats than one burst transfers nothing at all.
  constant bad_fewer_beats_than_one_burst : natural := BEATS - MAXB;

  type st_t is (S_IDLE, S_LOAD, S_LDRAIN, S_SAVE, S_SDRAIN, S_DONE);
  signal st : st_t := S_IDLE;

  signal base_q : unsigned(ADDR_W-1 downto 0) := (others => '0');
  signal err_q  : std_logic := '0';
  signal done_q : std_logic := '0';

  -- ---- LOAD counters ---------------------------------------------------
  signal ar_i   : natural range 0 to BURSTS := 0;   -- next burst to request
  signal outst  : natural range 0 to MAXOUT := 0;   -- AR issued, RLAST not in
  signal rbeat  : natural range 0 to BEATS  := 0;   -- beats fully unpacked
  signal upk_i  : natural range 0 to WPB    := WPB; -- word being unpacked
  signal rbuf   : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  -- ---- SAVE counters ---------------------------------------------------
  -- TWO indices, and they must be separate.  The store read is REGISTERED, so
  -- the word requested at `req_i` arrives on the NEXT edge and is collected
  -- at `got_i = req_i - 1`.  The first draft of this file used ONE index and
  -- silently dropped the last word of every beat.
  signal aw_i   : natural range 0 to BURSTS := 0;
  signal wbeat  : natural range 0 to BEATS  := 0;   -- beats accepted by W
  signal req_i  : natural range 0 to WPB    := 0;   -- next word requested
  signal got_i  : natural range 0 to WPB    := 0;   -- next word collected
  -- READ LATENCY IS TWO EDGES, NOT ONE, AND THIS PIPELINE IS WHY.  This
  -- module registers `m_r_en`/`m_r_head/col/grp`, and `gdn_state_mem`
  -- registers the data, so a word requested in cycle k is readable in cycle
  -- k+2.  The first version compared `got_i < req_i`, which is a ONE-cycle
  -- lag, and every saved layer came out shifted by exactly one word --
  -- `got(i) = want(i-1)` across the whole transfer.  `llama_top.vhd:1066`
  -- states the same rule for the region file in as many words: "An element
  -- whose address is issued at edge k is therefore readable at edge k+2.
  -- Consuming it at k+1 reads whatever the port held from the PREVIOUS
  -- unit's last access."
  --
  -- Tracked as a shift register of "a request was issued this cycle" rather
  -- than as an index comparison, because the comparison form also has to
  -- handle `req_i` saturating at WPB and gets the LAST word of every beat
  -- wrong when it does.
  signal req_v  : std_logic_vector(1 downto 0) := "00";
  signal bx_i   : natural range 0 to BURSTS := 0;   -- B responses retired
  signal wbuf   : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  signal arv_q, rrd_q       : std_logic := '0';
  signal awv_q, wv_q, brd_q : std_logic := '0';
  signal mwe_q, mre_q       : std_logic := '0';
  signal mwa_q, mra_q       : natural range 0 to WORDS-1 := 0;
  signal mwd_q              : std_logic_vector(WBITS-1 downto 0)
                            := (others => '0');

  function addr_of_burst(b : natural; base : unsigned) return unsigned is
  begin
    return base + to_unsigned(b * MAXB * BPB, ADDR_W);
  end function;
begin
  busy <= '0' when st = S_IDLE else '1';
  done <= done_q;
  err  <= err_q;

  r_arvalid <= arv_q;
  r_arlen   <= std_logic_vector(to_unsigned(MAXB-1, 8));
  r_arsize  <= std_logic_vector(to_unsigned(clog2(BPB), 3));
  r_arburst <= "01";                                   -- INCR
  r_rready  <= rrd_q;
  r_araddr  <= std_logic_vector(addr_of_burst(ar_i, base_q));

  w_awvalid <= awv_q;
  w_awlen   <= std_logic_vector(to_unsigned(MAXB-1, 8));
  w_awsize  <= std_logic_vector(to_unsigned(clog2(BPB), 3));
  w_awburst <= "01";
  w_awaddr  <= std_logic_vector(addr_of_burst(aw_i, base_q));
  w_wvalid  <= wv_q;
  w_wdata   <= wbuf;
  w_wstrb   <= (others => '1');
  -- WLAST marks the last beat OF THE BURST, not of the transfer.
  w_wlast   <= '1' when (wbeat mod MAXB) = MAXB-1 else '0';
  w_bready  <= brd_q;

  m_w_en   <= mwe_q;
  m_w_head <= mwa_q / (DIM*NBR);
  m_w_col  <= (mwa_q / NBR) mod DIM;
  m_w_grp  <= mwa_q mod NBR;
  m_w_data <= mwd_q;
  m_r_en   <= mre_q;
  m_r_head <= mra_q / (DIM*NBR);
  m_r_col  <= (mra_q / NBR) mod DIM;
  m_r_grp  <= mra_q mod NBR;

  p : process(clk) is
  begin
    if rising_edge(clk) then
      done_q <= '0';
      mwe_q  <= '0';
      mre_q  <= '0';

      if rst = '1' then
        st <= S_IDLE; arv_q <= '0'; rrd_q <= '0'; awv_q <= '0';
        wv_q <= '0'; brd_q <= '0'; err_q <= '0';
        ar_i <= 0; outst <= 0; rbeat <= 0; upk_i <= WPB;
        aw_i <= 0; wbeat <= 0; req_i <= 0; got_i <= 0; bx_i <= 0;
        req_v <= "00";
      else
        case st is
          when S_IDLE =>
            if load_start = '1' or save_start = '1' then
              -- THE BASE IS LATCHED HERE AND READ FROM THE LATCH THEREAFTER.
              -- Same rule as every other adapter in this design: a field read
              -- part-way through a long operation is defect class (a).
              base_q <= unsigned(state_base)
                      + to_unsigned(layer * LAYER_STRIDE, ADDR_W);
              ar_i <= 0; outst <= 0; rbeat <= 0; upk_i <= WPB;
              aw_i <= 0; wbeat <= 0; req_i <= 0; got_i <= 0; bx_i <= 0;
              req_v <= "00";
              if load_start = '1' then
                st <= S_LOAD; arv_q <= '1'; rrd_q <= '1';
              else
                st <= S_SAVE; awv_q <= '1'; brd_q <= '1';
              end if;
            end if;

          -- ================= LOAD: HBM -> gdn_state_mem ===================
          when S_LOAD =>
            -- ---- AR issue, up to MAXOUT in flight ----------------------
            if arv_q = '1' and r_arready = '1' then
              ar_i  <= ar_i + 1;
              outst <= outst + 1;
              -- keep AR asserted only if there is another burst AND room
              if ar_i + 1 >= BURSTS or outst + 1 >= MAXOUT then
                arv_q <= '0';
              end if;
            elsif arv_q = '0' and ar_i < BURSTS and outst < MAXOUT then
              arv_q <= '1';
            end if;

            -- ---- R accept, then unpack WPB words at one per cycle -------
            -- `upk_i = WPB` means "no beat held": that is the only state in
            -- which RREADY is high, so a beat is never accepted on top of one
            -- still being unpacked.
            if upk_i = WPB then
              if r_rvalid = '1' and rrd_q = '1' then
                if r_rresp /= "00" then err_q <= '1'; end if;
                rbuf  <= r_rdata;
                upk_i <= 0;
                rrd_q <= '0';
                if r_rlast = '1' then outst <= outst - 1; end if;
              end if;
            else
              mwe_q <= '1';
              mwa_q <= rbeat*WPB + upk_i;
              mwd_q <= rbuf((upk_i+1)*WBITS-1 downto upk_i*WBITS);
              if upk_i = WPB-1 then
                upk_i <= WPB;
                if rbeat + 1 = BEATS then
                  rbeat <= rbeat + 1;
                  st    <= S_LDRAIN;
                else
                  rbeat <= rbeat + 1;
                  rrd_q <= '1';
                end if;
              else
                upk_i <= upk_i + 1;
              end if;
            end if;

          when S_LDRAIN =>
            -- Every AR retired.  A load that reports done with a burst still
            -- in flight leaves the tail of the layer holding the PREVIOUS
            -- layer's state, which is a wrong number and not a hang.
            rrd_q <= '0';
            if outst = 0 then st <= S_DONE; end if;

          -- ================= SAVE: gdn_state_mem -> HBM ===================
          when S_SAVE =>
            -- OUTSTANDING WRITES ARE BOUNDED BY MAXOUT, THE SAME AS READS.
            -- The first version issued AW as fast as the slave accepted, with
            -- no bound at all, so a layer of 64 beats put 16 address phases in
            -- flight.  That is legal AXI -- a real slave backpressures with
            -- AWREADY -- but it is not something to rely on, and it broke the
            -- bench's 8-deep slave outright.  MEASURED by the parameter
            -- sweep: every geometry with BURSTS > 8 died and every one at or
            -- below passed, which is exactly the shape of an unbounded
            -- producer meeting a finite queue.
            if awv_q = '1' and w_awready = '1' then
              aw_i <= aw_i + 1;
              if aw_i + 1 >= BURSTS or (aw_i + 1) - bx_i >= MAXOUT then
                awv_q <= '0';
              end if;
            elsif awv_q = '0' and aw_i < BURSTS and aw_i - bx_i < MAXOUT then
              awv_q <= '1';
            end if;

            -- ---- assemble one beat, WPB words, two-edge read ------------
            if wv_q = '0' then
              if req_i < WPB then
                mre_q  <= '1';
                mra_q  <= wbeat*WPB + req_i;
                req_i  <= req_i + 1;
                req_v  <= req_v(0) & '1';
              else
                req_v  <= req_v(0) & '0';
              end if;
              -- the word requested TWO cycles ago lands now
              if req_v(1) = '1' then
                wbuf((got_i+1)*WBITS-1 downto got_i*WBITS) <= m_r_data;
                if got_i = WPB-1 then
                  got_i <= 0;
                  req_i <= 0;
                  wv_q  <= '1';
                else
                  got_i <= got_i + 1;
                end if;
              end if;
            elsif w_wready = '1' then
              wv_q  <= '0';
              req_v <= "00";     -- the next beat starts with an empty pipe
              if wbeat + 1 = BEATS then
                wbeat <= wbeat + 1;
                st    <= S_SDRAIN;
              else
                wbeat <= wbeat + 1;
              end if;
            end if;

            if w_bvalid = '1' and brd_q = '1' then
              if w_bresp /= "00" then err_q <= '1'; end if;
              bx_i <= bx_i + 1;
            end if;

          when S_SDRAIN =>
            -- EVERY WRITE RETIRED, BRESP IN.  A save that reports done before
            -- its last BRESP has not been written, and the next token reads
            -- the previous token's state.  Same rule as attn_kv_axi's
            -- `wr_idle`.
            if w_bvalid = '1' and brd_q = '1' then
              if w_bresp /= "00" then err_q <= '1'; end if;
              bx_i <= bx_i + 1;
            end if;
            if bx_i = BURSTS then
              brd_q <= '0';
              st    <= S_DONE;
            end if;

          when S_DONE =>
            done_q <= '1';
            st     <= S_IDLE;
        end case;
      end if;
    end if;
  end process;
end architecture;
