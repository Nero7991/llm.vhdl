-- sim/kv_axi_harness.vhd -- one instance of rtl/attn_kv_axi.vhd, its three
-- AXI slaves, its consumer model and its checker.
--
-- It is a separate entity rather than inline in sim/tb_attn_kv_axi.vhd because
-- the unit has to be checked at TWO AXI data widths and the two cases cover
-- different mechanisms:
--
--   AXI_DW = 256   REC_B = 272 is 8.5 beats, so the 16-BYTE RECORD PHASE
--                  alternates with the parity of `pos` and the realignment mux
--                  is exercised on every other record.  A prefetch run of
--                  RBUF = 4 records is 35 beats, so the AXI3 16-beat cap
--                  splits it 16 + 16 + 3.  A single-record WRITE is 9 beats
--                  and never splits.
--   AXI_DW = 128   REC_B is exactly 17 beats, so the phase is always 0 and the
--                  realignment is never exercised -- but a single-record WRITE
--                  is 17 beats and splits 16 + 1, which is the only shape that
--                  reaches the write-side splitter at all.
--
-- Neither width covers both.  Writing the harness twice would have let the two
-- copies drift, which is the same reasoning the read engine's generate rests
-- on.
--
-- WHAT THE SLAVES CHECK, and why each check is here rather than in the DUT:
--   S1  ARLEN+1 <= MAXB and AWLEN+1 <= MAXB.  The FK33 HBM slave is AXI3 and
--       rtl/hbm_tg_ip.vhd:1036 truncates arlen(3 downto 0) at the pin, so a
--       17-beat burst does not fail, it silently becomes a 1-beat burst.  A
--       slave that did not check this would report a wrong ANSWER, not a
--       protocol error, which is how that defect escaped once already.
--   S2  no burst crosses a 4 KB boundary.
--   S3  the address is beat-aligned, ARBURST/AWBURST is INCR, ARSIZE/AWSIZE
--       matches the data width.
--   S4  every accepted burst delivers exactly LEN+1 beats and RLAST/WLAST
--       lands on the last one; at end of test AR count = RLAST count and
--       AW count = WLAST count = B count.  **This is the burst-completion
--       rule of rtl/hbm_tg.vhd:727: a datapath must finish what it issued,
--       because abandoning an accepted burst hangs the channel permanently.**
--   S5  RREADY is high on every cycle RVALID is -- the structural form of the
--       same rule on the read side.
--   S6  no read burst reaches a record at pos > cur_pos, and no read burst
--       leaves the (layer, kv_head) sub-region it started in.  C spec 2.4:
--       the record at cur_pos is written by this job through a different
--       master and reading it back is a race, not a cache hit.  A burst may
--       spill at most BEAT_B-1 bytes past the last readable record because
--       the record length is not a beat multiple; those bytes are discarded
--       and the check allows exactly that much and no more.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.textio.all;
use work.util_pkg.all;

entity kv_axi_harness is
  generic(
    TAG      : string   := "dw256";
    VECFILE  : string   := "attn_kv_axi_vec.txt";
    HEAD_DIM : positive := 256;
    KV_BLOCK : positive := 32;
    N_KVH    : positive := 2;
    LAYERS   : positive := 2;
    MAXCTX   : positive := 32;
    POS_W    : positive := 16;
    AXI_DW   : positive := 256;
    ADDR_W   : positive := 33;
    MAXB     : positive := 16;
    MAXOUT   : positive := 4;
    RBUF     : positive := 4;
    NB_MAX   : positive := 131072;  -- bytes of modelled memory
    STALL    : natural  := 5        -- 0 = no stalls; else 1-in-STALL gaps
  );
  port(
    clk  : in  std_logic;
    rst  : in  std_logic;
    fin  : out std_logic := '0';    -- this harness has finished
    ok   : out std_logic := '0'     -- ... and everything matched
  );
end entity;

architecture sim of kv_axi_harness is

  constant NBLK   : integer := HEAD_DIM/KV_BLOCK;
  constant CH_B   : integer := 16;
  constant REC_B  : integer := CH_B + HEAD_DIM;
  constant BEAT_B : integer := AXI_DW/8;
  constant AW_B   : integer := clog2(NBLK);
  constant AW_H   : integer := clog2(N_KVH);

  -- ---- the modelled memory.  A protected type, because the two read slaves
  -- and the write slave are three processes over ONE address space and a
  -- plain shared variable is illegal in VHDL-2008.
  type mem_t is protected
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0));
    impure function rdb(i : natural) return std_logic_vector;
  end protected;
  type mem_t is protected body
    type ba_t is array (0 to NB_MAX-1) of std_logic_vector(7 downto 0);
    variable a : ba_t := (others => (others => '0'));
    procedure wrb(i : natural; v : std_logic_vector(7 downto 0)) is
    begin a(i) := v; end procedure;
    impure function rdb(i : natural) return std_logic_vector is
    begin return a(i); end function;
  end protected body;
  shared variable mem : mem_t;

  -- ---- the vector file, held for the checker ---------------------------
  type i_arr is array (natural range <>) of integer;
  signal v_layer, v_cpos, v_ctx : integer := 0;
  signal v_imgb, v_kbase, v_vbase : integer := 0;
  signal v_nch, v_nw, v_nr : integer := 0;
  signal loaded : std_logic := '0';

  constant NW_MAX : integer := 8;
  constant NR_MAX : integer := 96;
  signal w_sel : i_arr(0 to NW_MAX-1) := (others => 0);
  signal w_hd  : i_arr(0 to NW_MAX-1) := (others => 0);
  signal w_ps  : i_arr(0 to NW_MAX-1) := (others => 0);
  type wh_t is array (0 to NW_MAX-1) of i_arr(0 to NBLK-1);
  type wm_t is array (0 to NW_MAX-1) of i_arr(0 to HEAD_DIM-1);
  signal w_hdr : wh_t := (others => (others => 0));
  signal w_mnt : wm_t := (others => (others => 0));

  signal r_sel : i_arr(0 to NR_MAX-1) := (others => 0);
  signal r_hd  : i_arr(0 to NR_MAX-1) := (others => 0);
  signal r_ps  : i_arr(0 to NR_MAX-1) := (others => 0);
  type rh_t is array (0 to NR_MAX-1) of i_arr(0 to NBLK-1);
  type rm_t is array (0 to NR_MAX-1) of i_arr(0 to HEAD_DIM-1);
  signal r_hdr : rh_t := (others => (others => 0));
  signal r_mnt : rm_t := (others => (others => 0));
  type ex_t is array (0 to 8191) of std_logic_vector(127 downto 0);
  signal expimg : ex_t := (others => (others => '0'));

  -- ---- DUT ports --------------------------------------------------------
  signal d_start : std_logic := '0';
  signal d_layer : integer range 0 to LAYERS-1 := 0;
  signal d_cpos, d_ctx : unsigned(POS_W-1 downto 0) := (others => '0');
  signal d_kb, d_vb : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal d_cfgt, d_busy, d_wridle, d_err : std_logic;

  signal kw_sel : std_logic := '0';
  signal kw_head : unsigned(AW_H-1 downto 0) := (others => '0');
  signal kw_pos  : unsigned(POS_W-1 downto 0) := (others => '0');
  signal kw_hen, kw_en : std_logic := '0';
  signal kw_hdr : std_logic_vector(NBLK*8-1 downto 0) := (others => '0');
  signal kw_blk : unsigned(AW_B-1 downto 0) := (others => '0');
  signal kw_mant: std_logic_vector(KV_BLOCK*8-1 downto 0) := (others => '0');
  signal kw_rdy : std_logic;

  signal kr_head, vr_head : unsigned(AW_H-1 downto 0) := (others => '0');
  signal kr_pos, vr_pos   : unsigned(POS_W-1 downto 0) := (others => '0');
  signal kr_en, vr_en     : std_logic := '0';
  signal kr_blk, vr_blk   : unsigned(AW_B-1 downto 0) := (others => '0');
  signal kr_rdy, vr_rdy   : std_logic;
  signal kr_hdr, vr_hdr   : std_logic_vector(NBLK*8-1 downto 0);
  signal kr_mant, vr_mant : std_logic_vector(KV_BLOCK*8-1 downto 0);

  signal r_arvalid, r_arready, r_rvalid, r_rready, r_rlast
        : std_logic_vector(1 downto 0);
  signal r_araddr : std_logic_vector(2*ADDR_W-1 downto 0);
  signal r_arlen  : std_logic_vector(15 downto 0);
  signal r_arsize : std_logic_vector(5 downto 0);
  signal r_arburst: std_logic_vector(3 downto 0);
  -- ONE SIGNAL PER STREAM, then concatenated.  A process that assigns to
  -- r_rdata(<expression involving a loop variable>) has `r_rdata` as its
  -- longest STATIC prefix, so it drives the WHOLE vector, not the slice it
  -- names -- and the two slave processes then resolve to 'X' on every bit.
  -- MEASURED: that is exactly what happened here, and it presented as the DUT
  -- reading zeros out of a memory the slave had just read correctly, with
  -- nothing but NUMERIC_STD metavalue warnings to say so.
  --
  -- The first fix -- two flat signals behind `if s = 0 then` -- did NOT work,
  -- and that is the part worth keeping: a DRIVER exists because the assignment
  -- statement is present in the process, not because it executes.  Both
  -- instances still drove both signals.  Indexing an ARRAY by the generate
  -- parameter is what actually splits them, because then the longest static
  -- prefix is `rdat(s)` and s differs per instance.
  type rd_arr is array (0 to 1) of std_logic_vector(AXI_DW-1 downto 0);
  signal rdat     : rd_arr := (others => (others => '0'));
  signal r_rdata  : std_logic_vector(2*AXI_DW-1 downto 0)
                  := (others => '0');
  signal r_rresp  : std_logic_vector(3 downto 0) := (others => '0');

  signal w_awvalid, w_awready, w_wvalid, w_wready, w_wlast : std_logic;
  signal w_bvalid : std_logic := '0';
  signal w_bready : std_logic;
  signal w_awaddr : std_logic_vector(ADDR_W-1 downto 0);
  signal w_awlen  : std_logic_vector(7 downto 0);
  signal w_awsize : std_logic_vector(2 downto 0);
  signal w_awburst: std_logic_vector(1 downto 0);
  signal w_wdata  : std_logic_vector(AXI_DW-1 downto 0);
  signal w_wstrb  : std_logic_vector(AXI_DW/8-1 downto 0);
  signal w_bresp  : std_logic_vector(1 downto 0) := "00";

  -- ---- bookkeeping for S4 ----------------------------------------------
  signal n_ar, n_rlast : i_arr(0 to 1) := (others => 0);
  signal n_aw, n_wlast, n_b : integer := 0;
  -- COVERAGE, not decoration: a splitter that never split and a phase that
  -- was always zero would pass every check above while proving nothing.
  signal n_cap  : i_arr(0 to 1) := (others => 0);  -- bursts at the MAXB cap
  signal n_4k   : i_arr(0 to 1) := (others => 0);  -- bursts ending on 4 KB
  signal n_ph   : i_arr(0 to 1) := (others => 0);  -- run starts with phase
  signal n_wcap : integer := 0;
  -- Per stream, then summed: two processes cannot drive one integer signal.
  signal n_arflush : i_arr(0 to 1) := (others => 0);
  signal n_w4k  : integer := 0;
  signal n_wph  : integer := 0;
  signal bad : integer := 0;

  -- ---- capture of the consumer reads -----------------------------------
  signal cap_n : integer := 0;
  type cap_t is array (0 to 63) of std_logic_vector(KV_BLOCK*8-1 downto 0);
  signal cap_k, cap_v : cap_t := (others => (others => '0'));
  signal cap_kh, cap_vh : std_logic_vector(NBLK*8-1 downto 0)
                        := (others => '0');
  signal cap_kn, cap_vn : integer := 0;
  signal cap_rst : std_logic := '0';

  function hexch(c : character) return integer is
  begin
    case c is
      when '0' => return 0;  when '1' => return 1;  when '2' => return 2;
      when '3' => return 3;  when '4' => return 4;  when '5' => return 5;
      when '6' => return 6;  when '7' => return 7;  when '8' => return 8;
      when '9' => return 9;  when 'a'|'A' => return 10;
      when 'b'|'B' => return 11; when 'c'|'C' => return 12;
      when 'd'|'D' => return 13; when 'e'|'E' => return 14;
      when 'f'|'F' => return 15;
      when others => return -1;
    end case;
  end function;

  function rec_addr(base, lay, hd, ps : integer) return integer is
  begin
    return base + (((lay*N_KVH + hd)*MAXCTX) + ps)*REC_B;
  end function;

begin

  ---------------------------------------------------------------------------
  -- the DUT
  ---------------------------------------------------------------------------
  dut : entity work.attn_kv_axi
    generic map(HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK, N_KVH => N_KVH,
                LAYERS => LAYERS, MAXCTX => MAXCTX, POS_W => POS_W,
                CM_W => 8, EXP_W => 8, AXI_DW => AXI_DW, ADDR_W => ADDR_W,
                MAXB => MAXB, MAXOUT => MAXOUT, RBUF => RBUF)
    port map(
      clk => clk, rst => rst,
      start => d_start, layer => d_layer, cur_pos => d_cpos, ctx_len => d_ctx,
      k_base => d_kb, v_base => d_vb,
      cfg_taken => d_cfgt, busy => d_busy, wr_idle => d_wridle, err => d_err,
      kw_sel => kw_sel, kw_head => kw_head, kw_pos => kw_pos,
      kw_hen => kw_hen, kw_hdr => kw_hdr, kw_en => kw_en, kw_blk => kw_blk,
      kw_mant => kw_mant, kw_rdy => kw_rdy,
      kr_head => kr_head, kr_pos => kr_pos, kr_rdy => kr_rdy, kr_en => kr_en,
      kr_blk => kr_blk, kr_hdr => kr_hdr, kr_mant => kr_mant,
      vr_head => vr_head, vr_pos => vr_pos, vr_rdy => vr_rdy, vr_en => vr_en,
      vr_blk => vr_blk, vr_hdr => vr_hdr, vr_mant => vr_mant,
      r_arvalid => r_arvalid, r_arready => r_arready, r_araddr => r_araddr,
      r_arlen => r_arlen, r_arsize => r_arsize, r_arburst => r_arburst,
      r_rvalid => r_rvalid, r_rready => r_rready, r_rdata => r_rdata,
      r_rlast => r_rlast, r_rresp => r_rresp,
      w_awvalid => w_awvalid, w_awready => w_awready, w_awaddr => w_awaddr,
      w_awlen => w_awlen, w_awsize => w_awsize, w_awburst => w_awburst,
      w_wvalid => w_wvalid, w_wready => w_wready, w_wdata => w_wdata,
      w_wstrb => w_wstrb, w_wlast => w_wlast,
      w_bvalid => w_bvalid, w_bready => w_bready, w_bresp => w_bresp);

  r_rdata <= rdat(1) & rdat(0);

  ---------------------------------------------------------------------------
  -- the two read slaves.  Clocked, with an AR queue, so MAXOUT is real.
  ---------------------------------------------------------------------------
  GEN_SLV : for s in 0 to 1 generate
    signal arr   : std_logic := '0';
    signal arv_d : std_logic := '0';
    signal ara_d : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
    signal arl_d : std_logic_vector(7 downto 0) := (others => '0');
  begin
    r_arready(s) <= arr;
    P_SLV : process(clk)
      constant QD : integer := 8;
      type qa_t is array (0 to QD-1) of integer;
      variable qa, ql : qa_t := (others => 0);
      variable qh, qt, qn : integer := 0;
      variable busyb : boolean := false;
      variable badr, bleft : integer := 0;
      variable lf : unsigned(15 downto 0) := to_unsigned(7919 + s*331, 16);
      variable a, n, base, blkoff, lo, hi, sub : integer;
    begin
      if rising_edge(clk) then
        lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
        if rst = '1' then
          qh := 0; qt := 0; qn := 0; busyb := false;
          arr <= '0'; arv_d <= '0'; r_rvalid(s) <= '0'; r_rlast(s) <= '0';
        else
          -- S5: RREADY must stand whenever RVALID does.
          if r_rvalid(s) = '1' and r_rready(s) /= '1' then
            report TAG & ": RREADY LOW while RVALID high on read master "
                 & integer'image(s)
                 & " -- an accepted burst is being stalled indefinitely"
              severity failure;
          end if;

          -- AXI3 A3.1.2: once ARVALID is asserted it must stand until
          -- ARREADY.  A master that withdraws it under a flush corrupts the
          -- channel in exactly the way an abandoned burst does, so it is
          -- checked here rather than assumed.
          if arv_d = '1' and arr = '0' then
            assert r_arvalid(s) = '1'
              report TAG & ": read master " & integer'image(s)
                   & " WITHDREW ARVALID before ARREADY" severity failure;
            assert r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W) = ara_d
                   and r_arlen((s+1)*8-1 downto s*8) = arl_d
              report TAG & ": read master " & integer'image(s)
                   & " changed ARADDR/ARLEN while ARVALID was pending"
              severity failure;
          end if;
          if r_arvalid(s) = '1' and d_busy = '1' then
            n_arflush(s) <= n_arflush(s) + 1;
          end if;
          arv_d <= r_arvalid(s) and not arr;
          ara_d <= r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W);
          arl_d <= r_arlen((s+1)*8-1 downto s*8);

          arr <= '0';
          -- ---- AR accept ------------------------------------------------
          -- The refusal is not a stress knob, it is what makes the ARVALID
          -- stability check above ABLE TO FIRE.  A slave that answers every AR
          -- on the next cycle never leaves ARVALID pending, so a master that
          -- withdraws it under a flush is invisible: MEASURED, mutation D2
          -- survived until this line existed.
          if r_arvalid(s) = '1' and qn < QD and arr = '0'
             and (to_integer(lf) mod 8) = 0 then
            a := to_integer(unsigned(r_araddr((s+1)*ADDR_W-1 downto s*ADDR_W)));
            n := to_integer(unsigned(r_arlen((s+1)*8-1 downto s*8))) + 1;
            -- S1
            assert n <= MAXB
              report TAG & ": read master " & integer'image(s) & " ARLEN+1 = "
                   & integer'image(n) & " > MAXB = " & integer'image(MAXB)
                   & " -- THE HBM SLAVE IS AXI3, arlen is 4 bits and this "
                   & "silently wraps at the pin (rtl/hbm_tg_ip.vhd:1036)"
              severity failure;
            -- S2
            assert (a mod 4096) + n*BEAT_B <= 4096
              report TAG & ": read master " & integer'image(s)
                   & " burst at " & integer'image(a) & " of "
                   & integer'image(n) & " beats CROSSES A 4 KB BOUNDARY"
              severity failure;
            -- S3
            assert (a mod BEAT_B) = 0
              report TAG & ": read master " & integer'image(s)
                   & " ARADDR is not beat aligned" severity failure;
            assert r_arburst((s+1)*2-1 downto s*2) = "01"
              report TAG & ": read master " & integer'image(s)
                   & " ARBURST is not INCR" severity failure;
            assert to_integer(unsigned(r_arsize((s+1)*3-1 downto s*3)))
                   = clog2(BEAT_B)
              report TAG & ": read master " & integer'image(s)
                   & " ARSIZE does not match the data width" severity failure;
            -- S6: stay inside the (layer, head) sub-region, and never reach a
            -- record beyond cur_pos.  The last beat may spill at most
            -- BEAT_B-1 bytes past the last readable record; those bytes are
            -- discarded by the DUT and the bound allows exactly that.
            if s = 0 then base := v_kbase; else base := v_vbase; end if;
            -- the burst may START up to BEAT_B-16 bytes BELOW the first
            -- record of the sub-region, because the record phase is 16 and
            -- the AR must be beat aligned.  Adding one granule back before
            -- the divide recovers the sub-region index; the range assert
            -- below then re-checks the whole burst against it.
            sub := (a - base + CH_B) / (MAXCTX*REC_B);
            lo  := rec_addr(base, sub/N_KVH, sub mod N_KVH, 0);
            hi  := rec_addr(base, sub/N_KVH, sub mod N_KVH, v_cpos);
            assert a >= lo - BEAT_B and a + n*BEAT_B <= hi + BEAT_B
              report TAG & ": read master " & integer'image(s)
                   & " burst [" & integer'image(a) & ","
                   & integer'image(a + n*BEAT_B)
                   & ") leaves the readable range [" & integer'image(lo)
                   & "," & integer'image(hi + BEAT_B)
                   & ") -- it reads the current position, or another "
                   & "(layer, kv head) sub-region" severity failure;
            arr <= '1';
            qa(qt) := a; ql(qt) := n;
            qt := (qt + 1) mod QD; qn := qn + 1;
            n_ar(s) <= n_ar(s) + 1;
            if n = MAXB then n_cap(s) <= n_cap(s) + 1; end if;
            if (a + n*BEAT_B) mod 4096 = 0 then n_4k(s) <= n_4k(s) + 1; end if;
            if ((a - base) mod REC_B) /= 0 then n_ph(s) <= n_ph(s) + 1; end if;
          end if;

          -- ---- R delivery -----------------------------------------------
          if r_rvalid(s) = '1' and r_rready(s) = '1' then
            bleft := bleft - 1;
            badr  := badr + BEAT_B;
            if bleft = 0 then
              busyb := false;
              r_rvalid(s) <= '0'; r_rlast(s) <= '0';
              n_rlast(s) <= n_rlast(s) + 1;
            end if;
          end if;
          if not busyb and qn > 0 then
            badr  := qa(qh); bleft := ql(qh);
            qh := (qh + 1) mod QD; qn := qn - 1;
            busyb := true;
          end if;
          if busyb and (r_rvalid(s) = '0' or r_rready(s) = '1') then
            if STALL > 1 and (to_integer(lf) mod STALL) = 0 then
              r_rvalid(s) <= '0';
            else
              if bleft > 0 then
                for c in 0 to BEAT_B-1 loop
                  rdat(s)((c+1)*8-1 downto c*8) <= mem.rdb(badr - v_imgb + c);
                end loop;
                r_rvalid(s) <= '1';
                if bleft = 1 then r_rlast(s) <= '1';
                else r_rlast(s) <= '0'; end if;
              end if;
            end if;
          end if;
        end if;
      end if;
    end process;
  end generate;

  ---------------------------------------------------------------------------
  -- the write slave
  ---------------------------------------------------------------------------
  P_WSLV : process(clk)
    constant QD : integer := 8;
    type qa_t is array (0 to QD-1) of integer;
    variable qa, ql : qa_t := (others => 0);
    variable qh, qt, qn : integer := 0;
    variable busyb : boolean := false;
    variable badr, bleft : integer := 0;
    variable a, n : integer;
    variable bq : integer := 0;      -- B responses owed
  begin
    if rising_edge(clk) then
      if rst = '1' then
        qh := 0; qt := 0; qn := 0; busyb := false; bq := 0;
        w_awready <= '0'; w_wready <= '0'; w_bvalid <= '0';
      else
        w_awready <= '0';
        w_wready  <= '1';
        if w_awvalid = '1' and qn < QD and w_awready = '0' then
          a := to_integer(unsigned(w_awaddr));
          n := to_integer(unsigned(w_awlen)) + 1;
          assert n <= MAXB
            report TAG & ": write master AWLEN+1 = " & integer'image(n)
                 & " > MAXB = " & integer'image(MAXB)
                 & " -- AXI3, 4-bit awlen" severity failure;
          assert (a mod 4096) + n*BEAT_B <= 4096
            report TAG & ": write burst at " & integer'image(a) & " of "
                 & integer'image(n) & " beats CROSSES A 4 KB BOUNDARY"
            severity failure;
          assert (a mod BEAT_B) = 0
            report TAG & ": AWADDR is not beat aligned" severity failure;
          assert w_awburst = "01"
            report TAG & ": AWBURST is not INCR" severity failure;
          assert to_integer(unsigned(w_awsize)) = clog2(BEAT_B)
            report TAG & ": AWSIZE does not match the data width"
            severity failure;
          w_awready <= '1';
          qa(qt) := a; ql(qt) := n; qt := (qt + 1) mod QD; qn := qn + 1;
          n_aw <= n_aw + 1;
          if n = MAXB then n_wcap <= n_wcap + 1; end if;
          if (a + n*BEAT_B) mod 4096 = 0 then n_w4k <= n_w4k + 1; end if;
          if (a mod BEAT_B) = 0 and ((a - v_kbase) mod REC_B) /= 0
             and ((a - v_vbase) mod REC_B) /= 0 then
            n_wph <= n_wph + 1;
          end if;
        end if;

        if not busyb and qn > 0 then
          badr := qa(qh); bleft := ql(qh);
          qh := (qh + 1) mod QD; qn := qn - 1;
          busyb := true;
        end if;
        if busyb and w_wvalid = '1' and w_wready = '1' then
          for c in 0 to BEAT_B-1 loop
            if w_wstrb(c) = '1' then
              mem.wrb(badr - v_imgb + c, w_wdata((c+1)*8-1 downto c*8));
            end if;
          end loop;
          bleft := bleft - 1;
          badr  := badr + BEAT_B;
          if bleft = 0 then
            assert w_wlast = '1'
              report TAG & ": WLAST missing on the last beat of a write burst"
              severity failure;
            busyb := false; bq := bq + 1;
            n_wlast <= n_wlast + 1;
          else
            assert w_wlast = '0'
              report TAG & ": WLAST asserted early in a write burst"
              severity failure;
          end if;
        end if;

        -- C spec 2.7 as a PROPERTY, not as an end-of-test poll: `done` may
        -- not assert while a write is unretired, so `wr_idle` must be low on
        -- every cycle a BRESP is owed.  Sampling it only at the end of the
        -- job cannot see this -- MEASURED, mutation V4 survived until here.
        if bq > 0 then
          assert d_wridle = '0'
            report TAG & ": wr_idle is HIGH while " & integer'image(bq)
                 & " write burst(s) have no BRESP -- token T+1 would read "
                 & "K/V[cur_pos] through a different master before token T's "
                 & "write retired (C spec 2.7)" severity failure;
        end if;
        if w_bvalid = '1' and w_bready = '1' then
          w_bvalid <= '0'; bq := bq - 1; n_b <= n_b + 1;
        end if;
        if bq > 0 and w_bvalid = '0' then
          w_bvalid <= '1'; w_bresp <= "00";
        end if;
      end if;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- the consumer's capture, one cycle behind the enable.  This is the same
  -- shape as rtl/attn_block.vhd's rbv pipeline: the data of an enable at edge
  -- E is registered by the DUT at E and is readable at E+1.
  ---------------------------------------------------------------------------
  P_CAP : process(clk)
    variable ke, ve : std_logic := '0';
    variable kn, vn : integer := 0;
  begin
    if rising_edge(clk) then
      if cap_rst = '1' then
        kn := 0; vn := 0; ke := '0'; ve := '0';
      else
        if ke = '1' then
          cap_k(kn) <= kr_mant; cap_kh <= kr_hdr; kn := kn + 1;
        end if;
        if ve = '1' then
          cap_v(vn) <= vr_mant; cap_vh <= vr_hdr; vn := vn + 1;
        end if;
        ke := kr_en; ve := vr_en;
      end if;
      cap_kn <= kn; cap_vn <= vn;
    end if;
  end process;

  ---------------------------------------------------------------------------
  -- the stimulus and the checker
  ---------------------------------------------------------------------------
  P_MAIN : process
    file     fh   : text;
    variable ln   : line;
    variable ok_o : file_open_status;
    variable s32  : string(1 to 32);
    variable iv   : integer;
    variable cnt  : integer;
    variable nbad : integer := 0;
    variable ch   : std_logic_vector(127 downto 0);
    variable exp_i, got_i : integer;
    variable nrh  : integer := 0;

    procedure tick is begin wait until rising_edge(clk); end procedure;

    -- one full record read through port `sel`, exactly as attn_block issues
    -- it: hold the request, wait for residency, then NBLK enables back to
    -- back with no gap.
    procedure do_read(sel, hd, ps, ri : integer) is
      variable e, g : integer;
    begin
      cap_rst <= '1'; tick; cap_rst <= '0'; tick;
      if sel = 0 then
        kr_head <= to_unsigned(hd, AW_H); kr_pos <= to_unsigned(ps, POS_W);
      else
        vr_head <= to_unsigned(hd, AW_H); vr_pos <= to_unsigned(ps, POS_W);
      end if;
      tick;
      cnt := 0;
      loop
        exit when (sel = 0 and kr_rdy = '1') or (sel = 1 and vr_rdy = '1');
        cnt := cnt + 1;
        assert cnt < 100000
          report TAG & ": residency never arrived for sel=" & integer'image(sel)
               & " head=" & integer'image(hd) & " pos=" & integer'image(ps)
          severity failure;
        tick;
      end loop;
      for b in 0 to NBLK-1 loop
        if sel = 0 then kr_en <= '1'; kr_blk <= to_unsigned(b, AW_B);
        else            vr_en <= '1'; vr_blk <= to_unsigned(b, AW_B); end if;
        tick;
      end loop;
      kr_en <= '0'; vr_en <= '0';
      tick; tick;
      -- compare, bit for bit, against the oracle's structured record
      for b in 0 to NBLK-1 loop
        e := r_hdr(ri)(b);
        if sel = 0 then
          g := to_integer(signed(cap_kh((b+1)*8-1 downto b*8)));
        else
          g := to_integer(signed(cap_vh((b+1)*8-1 downto b*8)));
        end if;
        if e /= g then
          nbad := nbad + 1;
          if nbad < 12 then
            report TAG & ": HEADER MISMATCH req " & integer'image(ri)
                 & " sel=" & integer'image(sel) & " head=" & integer'image(hd)
                 & " pos=" & integer'image(ps) & " blk=" & integer'image(b)
                 & " oracle=" & integer'image(e) & " rtl=" & integer'image(g)
              severity error;
          end if;
        end if;
        for k in 0 to KV_BLOCK-1 loop
          e := r_mnt(ri)(b*KV_BLOCK + k);
          if sel = 0 then
            g := to_integer(signed(cap_k(b)((k+1)*8-1 downto k*8)));
          else
            g := to_integer(signed(cap_v(b)((k+1)*8-1 downto k*8)));
          end if;
          if e /= g then
            nbad := nbad + 1;
            if nbad < 12 then
              report TAG & ": MANTISSA MISMATCH req " & integer'image(ri)
                   & " sel=" & integer'image(sel) & " head=" & integer'image(hd)
                   & " pos=" & integer'image(ps) & " blk=" & integer'image(b)
                   & " el=" & integer'image(k)
                   & " oracle=" & integer'image(e) & " rtl=" & integer'image(g)
                severity error;
            end if;
          end if;
        end loop;
      end loop;
    end procedure;

    procedure do_write(wi : integer) is
    begin
      while kw_rdy = '0' loop tick; end loop;
      kw_sel  <= '0'; if w_sel(wi) = 1 then kw_sel <= '1'; end if;
      kw_head <= to_unsigned(w_hd(wi), AW_H);
      kw_pos  <= to_unsigned(w_ps(wi), POS_W);
      for b in 0 to NBLK-1 loop
        kw_hdr((b+1)*8-1 downto b*8)
          <= std_logic_vector(to_signed(w_hdr(wi)(b), 8));
      end loop;
      kw_hen <= '1'; tick; kw_hen <= '0';
      for b in 0 to NBLK-1 loop
        for k in 0 to KV_BLOCK-1 loop
          kw_mant((k+1)*8-1 downto k*8)
            <= std_logic_vector(to_signed(w_mnt(wi)(b*KV_BLOCK + k), 8));
        end loop;
        kw_blk <= to_unsigned(b, AW_B);
        kw_en  <= '1'; tick;
      end loop;
      kw_en <= '0'; tick;
    end procedure;

  begin
    ----------------------------------------------------------------------
    -- load the vector file
    ----------------------------------------------------------------------
    file_open(ok_o, fh, VECFILE, read_mode);
    assert ok_o = open_ok
      report TAG & ": cannot open " & VECFILE severity failure;
    readline(fh, ln);                       -- "KVAXI 1"
    readline(fh, ln);
    read(ln, iv); assert iv = HEAD_DIM
      report TAG & ": vector HEAD_DIM /= generic" severity failure;
    read(ln, iv); assert iv = KV_BLOCK
      report TAG & ": vector KV_BLOCK /= generic" severity failure;
    read(ln, iv); assert iv = N_KVH
      report TAG & ": vector N_KVH /= generic" severity failure;
    read(ln, iv); assert iv = LAYERS
      report TAG & ": vector LAYERS /= generic" severity failure;
    read(ln, iv); assert iv = MAXCTX
      report TAG & ": vector MAXCTX /= generic" severity failure;
    readline(fh, ln);
    read(ln, iv); v_layer <= iv;
    read(ln, iv); v_cpos  <= iv;
    read(ln, iv); v_ctx   <= iv;
    readline(fh, ln);
    read(ln, iv); v_imgb  <= iv;
    read(ln, iv); v_kbase <= iv;
    read(ln, iv); v_vbase <= iv;
    read(ln, iv); v_nch   <= iv;
    wait for 0 ns;

    readline(fh, ln);                       -- "IMG"
    for c in 0 to v_nch-1 loop
      readline(fh, ln);
      read(ln, s32);
      for b in 0 to 15 loop
        -- s32 is printed byte 15 first, so byte b is at 32-2*b-1 .. 32-2*b
        mem.wrb(c*16 + b,
          std_logic_vector(to_unsigned(hexch(s32(31 - 2*b)) * 16
                                     + hexch(s32(32 - 2*b)), 8)));
      end loop;
    end loop;
    readline(fh, ln);                       -- "EXPIMG"
    for c in 0 to v_nch-1 loop
      readline(fh, ln);
      read(ln, s32);
      for b in 0 to 15 loop
        ch((b+1)*8-1 downto b*8) :=
          std_logic_vector(to_unsigned(hexch(s32(31 - 2*b)) * 16
                                     + hexch(s32(32 - 2*b)), 8));
      end loop;
      expimg(c) <= ch;
      wait for 0 ns;
    end loop;

    readline(fh, ln);                       -- "NW n"
    read(ln, s32(1 to 2)); read(ln, iv); v_nw <= iv; wait for 0 ns;
    for w in 0 to v_nw-1 loop
      readline(fh, ln);
      read(ln, iv); w_sel(w) <= iv;
      read(ln, iv); w_hd(w)  <= iv;
      read(ln, iv); w_ps(w)  <= iv;
      readline(fh, ln);
      for b in 0 to NBLK-1 loop read(ln, iv); w_hdr(w)(b) <= iv; end loop;
      for b in 0 to NBLK-1 loop
        readline(fh, ln);
        for k in 0 to KV_BLOCK-1 loop
          read(ln, iv); w_mnt(w)(b*KV_BLOCK + k) <= iv;
        end loop;
      end loop;
      wait for 0 ns;
    end loop;

    readline(fh, ln);                       -- "NR n"
    read(ln, s32(1 to 2)); read(ln, iv); v_nr <= iv; wait for 0 ns;
    assert v_nr <= NR_MAX
      report TAG & ": too many read requests for NR_MAX" severity failure;
    for r in 0 to v_nr-1 loop
      readline(fh, ln);
      read(ln, iv); r_sel(r) <= iv;
      read(ln, iv); r_hd(r)  <= iv;
      read(ln, iv); r_ps(r)  <= iv;
      readline(fh, ln);
      for b in 0 to NBLK-1 loop read(ln, iv); r_hdr(r)(b) <= iv; end loop;
      for b in 0 to NBLK-1 loop
        readline(fh, ln);
        for k in 0 to KV_BLOCK-1 loop
          read(ln, iv); r_mnt(r)(b*KV_BLOCK + k) <= iv;
        end loop;
      end loop;
      wait for 0 ns;
    end loop;
    file_close(fh);
    loaded <= '1';
    wait for 0 ns;

    ----------------------------------------------------------------------
    -- run
    ----------------------------------------------------------------------
    d_layer <= v_layer;
    d_cpos  <= to_unsigned(v_cpos, POS_W);
    d_ctx   <= to_unsigned(v_ctx, POS_W);
    d_kb    <= std_logic_vector(to_unsigned(v_kbase, ADDR_W));
    d_vb    <= std_logic_vector(to_unsigned(v_vbase, ADDR_W));
    wait until rst = '0';
    tick; tick;
    -- Wait for `cfg_taken`, NOT for `busy` to fall.  `busy` is a concurrent
    -- assignment from `flushing`, so it carries a delta: polling it in the
    -- delta right after the `start` edge reads the OLD value and lets the
    -- first record be driven into a unit that is still flushing, which
    -- discards it silently.  MEASURED: that is exactly what happened, and it
    -- presented as one write record missing from the image with no error
    -- anywhere.  `cfg_taken` pulses on the cycle the new job is latched, which
    -- is the instant the contract actually names.
    d_start <= '1'; tick; d_start <= '0';
    cnt := 0;
    loop
      tick; cnt := cnt + 1;
      exit when d_cfgt = '1';
      assert cnt < 10000 report TAG & ": cfg_taken never pulsed"
        severity failure;
    end loop;
    tick;
    assert d_busy = '0'
      report TAG & ": busy is still high after cfg_taken" severity error;
    assert d_wridle = '1'
      report TAG & ": wr_idle is not high before the first write"
      severity error;

    -- attn_block's order: write this head's K and V records, then sweep this
    -- head's cached positions, then move to the next KV head.
    for hd in 0 to N_KVH-1 loop
      for w in 0 to v_nw-1 loop
        if w_hd(w) = hd then do_write(w); end if;
      end loop;
      nrh := 0;
      for r in 0 to v_nr-1 loop
        if r_hd(r) = hd and r < 2*N_KVH*v_cpos then
          do_read(r_sel(r), r_hd(r), r_ps(r), r);
          nrh := nrh + 1;
          -- A `start` here, six records into the sweep, is the ONLY point in
          -- this test where the fetcher is still running ahead: at the end of
          -- a head's sweep it has already reached the last readable record and
          -- has nothing outstanding, so a flush there drains an idle unit.
          -- MEASURED: with the flush only at the end of a head, ARVALID was
          -- pending during a flush on ZERO cycles of the whole run, and the
          -- ARVALID-stability check could not fire however correct it was.
          if nrh = 6 then
            -- Line the flush up with a PENDING AR on purpose.  Leaving it to
            -- chance does not work: MEASURED, with the flush placed at an
            -- arbitrary instant, ARVALID was high during a flush on ZERO
            -- cycles of the entire run, so the ARVALID-stability check could
            -- not fire however correct it was, and a master that withdraws an
            -- AR under a flush passed.  Waiting for `arvalid and not arready`
            -- is the harness timing its stimulus off the protocol, which is
            -- what a directed protocol test is for.
            -- Pulse `start` two cycles after a record completes.  The
            -- consumer has just advanced, so the fetcher issues its next AR
            -- immediately, and the slave accepts only one cycle in eight, so
            -- that AR is still pending when the flush lands.
            --
            -- WAITING for a pending AR instead does NOT work and the reason is
            -- worth keeping: the fetcher only issues when the CONSUMER
            -- advances, so a stimulus process that parks in a wait loop stops
            -- the very traffic it is waiting for.  MEASURED: 2,000 cycles in
            -- that loop with zero ARs issued.
            tick; tick;
            d_start <= '1'; tick; d_start <= '0';
            cnt := 0;
            loop
              tick; cnt := cnt + 1;
              exit when d_cfgt = '1';
              assert cnt < 10000
                report TAG & ": the mid-sweep drain never completed"
                severity failure;
            end loop;
            tick;
          end if;
        end if;
      end loop;
      -- A `start` in the MIDDLE of live traffic, once per KV head.  Both read
      -- engines are prefetching at this instant, so this is the drain-then-
      -- flush of C spec 2.7 under the condition it exists for, rather than
      -- against an idle unit.  The reads after it must still be bit-exact,
      -- which is what says the flush left nothing behind.
      d_start <= '1'; tick; d_start <= '0';
      cnt := 0;
      loop
        tick; cnt := cnt + 1;
        exit when d_cfgt = '1';
        assert cnt < 10000
          report TAG & ": the mid-sweep drain never completed" severity failure;
      end loop;
      tick;
    end loop;
    -- the four appended backward jumps: not part of the sweep, they exist to
    -- force the retarget path
    for r in 2*N_KVH*v_cpos to v_nr-1 loop
      do_read(r_sel(r), r_hd(r), r_ps(r), r);
    end loop;

    -- DRAIN-THEN-FLUSH, as a test rather than as an assumption.  `start` is
    -- pulsed with read bursts still outstanding: the unit must stop issuing,
    -- let every accepted burst finish, and only then flush.  The AR/RLAST
    -- balance below is what proves it, and it is also what proves the test
    -- did not simply stop with bursts in the air.
    -- Park both requests on the current position first: it is out of the
    -- readable range, so after the flush neither engine re-opens a run and
    -- the AR/RLAST balance below measures the drain rather than a fresh
    -- prefetch that started behind it.
    kr_pos <= to_unsigned(v_cpos, POS_W);
    vr_pos <= to_unsigned(v_cpos, POS_W);
    d_start <= '1'; tick; d_start <= '0';
    cnt := 0;
    loop
      tick; cnt := cnt + 1;
      exit when d_cfgt = '1';
      assert cnt < 10000
        report TAG & ": the drain never completed after start -- an "
             & "outstanding burst was never retired" severity failure;
    end loop;
    tick; tick;

    -- C spec 2.7: `done` may not assert until every write has its BRESP.
    cnt := 0;
    while d_wridle = '0' loop
      tick; cnt := cnt + 1;
      assert cnt < 10000 report TAG & ": wr_idle never rose" severity failure;
    end loop;

    ----------------------------------------------------------------------
    -- the image, byte for byte
    ----------------------------------------------------------------------
    for c in 0 to v_nch-1 loop
      for b in 0 to 15 loop
        got_i := to_integer(unsigned(mem.rdb(c*16 + b)));
        exp_i := to_integer(unsigned(expimg(c)((b+1)*8-1 downto b*8)));
        if got_i /= exp_i then
          nbad := nbad + 1;
          if nbad < 12 then
            report TAG & ": IMAGE MISMATCH at byte "
                 & integer'image(v_imgb + c*16 + b)
                 & " oracle=" & integer'image(exp_i)
                 & " rtl=" & integer'image(got_i) severity error;
          end if;
        end if;
      end loop;
    end loop;

    ----------------------------------------------------------------------
    -- S4: nothing was abandoned
    ----------------------------------------------------------------------
    for s in 0 to 1 loop
      if n_ar(s) /= n_rlast(s) then
        nbad := nbad + 1;
        report TAG & ": read master " & integer'image(s) & " issued "
             & integer'image(n_ar(s)) & " bursts and completed "
             & integer'image(n_rlast(s))
             & " -- AN ACCEPTED BURST WAS ABANDONED, which hangs the HBM "
             & "channel permanently (rtl/hbm_tg.vhd:727)" severity error;
      end if;
    end loop;
    if n_aw /= n_wlast or n_aw /= n_b then
      nbad := nbad + 1;
      report TAG & ": write master AW=" & integer'image(n_aw)
           & " WLAST=" & integer'image(n_wlast) & " B=" & integer'image(n_b)
           & " -- a write burst was abandoned" severity error;
    end if;
    if d_err /= '0' then
      nbad := nbad + 1;
      report TAG & ": err is set at the end of a clean job" severity error;
    end if;
    if n_ar(0) = 0 or n_ar(1) = 0 or n_aw = 0 then
      nbad := nbad + 1;
      report TAG & ": a master issued NO bursts at all -- the test is vacuous"
        severity error;
    end if;

    -- COVERAGE.  Every mechanism this unit exists for must have been reached
    -- at least once by SOME burst, or the checks above are vacuous.  Which
    -- mechanism a given width reaches differs, so the assert is on the union
    -- across the two harness instances and the per-instance numbers are
    -- printed rather than asserted.
    if n_arflush(0) + n_arflush(1) = 0 then
      nbad := nbad + 1;
      report TAG & ": ARVALID was never pending during a flush, so the "
           & "ARVALID-stability check never had anything to judge -- the "
           & "drain-then-flush test is vacuous on that axis" severity error;
    end if;
    if (n_cap(0) + n_cap(1) + n_wcap) = 0 then
      nbad := nbad + 1;
      report TAG & ": NO burst ever reached the MAXB cap -- the AXI3 burst "
           & "splitter was never exercised" severity error;
    end if;
    report TAG & " coverage: MAXB-capped bursts rd " & integer'image(n_cap(0))
         & "/" & integer'image(n_cap(1)) & " wr " & integer'image(n_wcap)
         & "; 4 KB-terminated rd " & integer'image(n_4k(0)) & "/"
         & integer'image(n_4k(1)) & " wr " & integer'image(n_w4k)
         & "; phase-shifted run starts rd " & integer'image(n_ph(0)) & "/"
         & integer'image(n_ph(1)) & " wr " & integer'image(n_wph)
         & "; ARVALID-pending-under-flush cycles "
         & integer'image(n_arflush(0) + n_arflush(1));

    report TAG & ": " & integer'image(v_nr) & " records, "
         & integer'image(v_nr*NBLK) & " headers-with-beat, "
         & integer'image(v_nr*HEAD_DIM) & " mantissas, "
         & integer'image(v_nch*16) & " image bytes; AR "
         & integer'image(n_ar(0)) & "/" & integer'image(n_ar(1))
         & " AW " & integer'image(n_aw)
         & "; mismatches " & integer'image(nbad);

    bad <= nbad;
    if nbad = 0 then ok <= '1'; else ok <= '0'; end if;
    fin <= '1';
    wait;
  end process;

end architecture;
