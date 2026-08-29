-- sim/tb_a_geom.vhd
-- DOES THE SCHEDULE GENERATOR'S IDEA OF SUBSYSTEM A's GEOMETRY MATCH THE
-- DESCRIPTOR PLANE'S?  Nothing asked that until this file existed.
--
-- THE DEFECT CLASS, named by TRACK TOKIO on 2026-08-29 after a whole track
-- spent fixing one instance of it.  `sim/seq_tbl_pkg.vhd:136-137` carries
--
--     constant A_ROWS_IF     : natural := 48;
--     constant A_MAXROWS_BFP : natural := 17408;
--
-- as LITERALS, and its own comment says why: "this package's whole point is to
-- derive the schedule from the MODEL and from nothing else, and these two are
-- properties of the BUILD".  That is right, and it leaves the two numbers
-- unconnected to the build.  `rtl/matvec_int4_desc_axi.vhd:102,108` carries
-- them again as generic DEFAULTS.  A divergence between the pair does not
-- produce an error anywhere: it produces a DESCRIPTOR TABLE THE GATEWARE
-- REFUSES, `err_code 0x3 err_info 1`, at run time, on the card -- which is
-- exactly what TOKIO's `80d3a61` had to repair.
--
-- WHAT THIS BENCH CHECKS, and both halves have real teeth.
--
--   ROWS_IF, at ELABORATION and again at run time.  The DUT is instantiated
--   with NO GENERIC MAP AT ALL, so every generic takes the entity's own
--   default -- this bench cannot restate ROWS_IF and then "check" its own
--   restatement, which is the shape of a check that cannot fail.  `y_data` is
--   declared `A_ROWS_IF*64` bits wide from `seq_tbl_pkg`, so a disagreement is
--   a PORT WIDTH MISMATCH and the analysis fails before any simulation runs.
--   The CAPS register (0x1C bits 23:16) is then read as well, so the failure
--   also has a readable message rather than only a width error.
--
--   MAXROWS_BFP, BEHAVIOURALLY, because it is in NO register.  The bench
--   builds two descriptors that differ in ONE field and lets the RTL judge:
--
--     n_rows = A_MAXROWS_BFP      must NOT be refused at descriptor word 1
--     n_rows = A_MAXROWS_BFP + 1  must be refused EC_DESC with err_info = 1
--
--   Those two together BRACKET the DUT's MAXROWS_BFP at exactly the value
--   `seq_tbl_pkg` believes.  A DUT bound below it fails the first; a DUT bound
--   above it fails the second.  `matvec_int4_desc_axi.vhd:721-726` is the site.
--
--   NPORTS_W / NPORTS_S, added 2026-08-29 by TRACK SCHED-FIX, at ELABORATION
--   (the 27 weight/scale port vectors are sized `A_NPORTS_W + A_NPORTS_S`) and
--   BEHAVIOURALLY, bracketed the same way at `matvec_int4_desc_axi.vhd:695-698`:
--
--     nsub = (A_NPORTS_W,   A_NPORTS_S)     must NOT be refused EC_GEOM
--     nsub = (A_NPORTS_W+1, A_NPORTS_S)     must be refused EC_GEOM, err_info 3
--     nsub = (A_NPORTS_W,   A_NPORTS_S+1)   must be refused EC_GEOM, err_info 3
--     nsub = (29, 4)                        must be refused EC_GEOM, err_info 3
--
--   The last is not a neighbourhood probe: it is the pair BOTH schedule
--   generators wrote into descriptor word 3 until 2026-08-29, taken from the
--   superseded ROWS_IF=58 port budget.  Nothing refused it, because
--   `seq_desc_fetch` only range-checks the field against NSUB_MAX = 64 and
--   `rtl/llama_top.vhd:2280` binds `matvec_int4`, which has no descriptor
--   plane, so no `tb_llama_top*` row contains an EC_GEOM check at all.
--
-- WHY "must NOT be refused at word 1" AND NOT "must be accepted".  The order
-- of S_CHECK's tests is: magic, version, ext flags, NPORTS, op, two pad words,
-- extension pads, out_mode, THEN the shape bound at word 1, then w_beats,
-- then the bases.  The bases here are deliberately not a valid weight image,
-- so the first descriptor is expected to be refused LATER, for a base reason.
-- Making it fully valid would mean packing a 17,408-row tensor into this
-- bench, which tests the packer and not the bound.  The observable that
-- isolates the bound is the FAILING WORD INDEX, and that is what is asserted.
--
-- WHAT IT DOES NOT COVER, stated rather than implied:
--   * `hw/fk33/gen_fk33_engine.py:85,91` carries the SAME two numbers a third
--     time, as Python literals, and the generated `hw/fk33/rtl/fk33_engine.vhd`
--     hardcodes `MAXROWS_BFP => 17408` in its instantiation, which OVERRIDES
--     the entity default this bench pins.  No VHDL elaboration can reach a
--     Python literal.  `tools/check_a_geometry.py` covers all four sites and
--     is NOT in this gate; see its header for why.
--   * `sim/tb_mv4i_desc_image.vhd` restates both numbers as generics too.
--     That is a fifth site and it is a BENCH, so a divergence there costs a
--     wrong test rather than a wrong build.
--
-- No clock beyond what the AXI-Lite and descriptor transactions need, no
-- weight traffic, and the 27 weight/scale slaves never answer.
library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use work.matvec_int4_desc_pkg.all;
use work.seq_tbl_pkg.A_ROWS_IF;
use work.seq_tbl_pkg.A_MAXROWS_BFP;
use work.seq_tbl_pkg.A_NPORTS_W;
use work.seq_tbl_pkg.A_NPORTS_S;

entity tb_a_geom is
end entity;

architecture sim of tb_a_geom is
  -- NPORTS_W / NPORTS_S ARE NOW SCHEDULE CONSTANTS TOO, and that is the
  -- 2026-08-29 change.  They used to be `24` and `3` written here, which made
  -- this bench check the DUT against its own restatement for those two fields
  -- -- the shape of a check that cannot fail.  Meanwhile BOTH schedule
  -- generators wrote `nsub_w = 29`, `nsub_s = 4` into descriptor word 3, the
  -- superseded ROWS_IF=58 port counts, and `matvec_int4_desc_axi.vhd:695-698`
  -- refuses exactly that with EC_GEOM before `start`.  Taking them from
  -- `seq_tbl_pkg` is what turns this row into the judge of that number:
  -- at 29 the DUT's ports are 27 lanes wide and `m_arvalid` here is 32, so
  -- the ANALYSIS fails, and the behavioural bracket below fails too.
  constant NPW    : positive := A_NPORTS_W;
  constant NPS    : positive := A_NPORTS_S;
  -- Still a restatement, and still not what this bench is about; CAPS is read
  -- below so a drifted restatement fails loudly rather than sizing ports wrong.
  constant AXI_DW : positive := 256;
  constant ADDR_W : positive := 40;

  constant NP_ALL : positive := NPW + NPS;
  constant PORT_B : positive := AXI_DW / 8;
  constant WPB    : positive := AXI_DW / 64;
  constant DWORDS : positive := desc_words(NPW, NPS);
  constant DBEATS : positive := desc_beats(NPW, NPS, AXI_DW);
  constant EXT0   : natural  := desc_ext0(NPW, NPS);
  -- A multiple of DESC_MAXB*AXI_DW/8 = 512, or the pointer raises ERR_ALIGN
  -- and the run never reaches S_CHECK at all.
  constant DESC_ADDR : natural := 16#300000#;

  signal clk      : std_logic := '0';
  signal aresetn  : std_logic := '0';
  signal finished : boolean   := false;

  signal awaddr, araddr_l : std_logic_vector(7 downto 0) := (others => '0');
  signal wdata, rdata_l   : std_logic_vector(31 downto 0) := (others => '0');
  signal wstrb  : std_logic_vector(3 downto 0) := "1111";
  signal awvalid, awready, wvalid, wready, bvalid, bready : std_logic := '0';
  signal arvalid_l, arready_l, rvalid_l, rready_l : std_logic := '0';
  signal bresp, rresp : std_logic_vector(1 downto 0);

  signal d_arvalid, d_arready, d_rvalid, d_rready, d_rlast : std_logic := '0';
  signal d_araddr  : std_logic_vector(ADDR_W-1 downto 0);
  signal d_arlen   : std_logic_vector(7 downto 0);
  signal d_arsize  : std_logic_vector(2 downto 0);
  signal d_arburst : std_logic_vector(1 downto 0);
  signal d_rdata   : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  signal m_arvalid, m_arready, m_rvalid, m_rready, m_rlast :
    std_logic_vector(NP_ALL-1 downto 0) := (others => '0');
  signal m_araddr  : std_logic_vector(NP_ALL*ADDR_W-1 downto 0);
  signal m_arlen   : std_logic_vector(NP_ALL*8-1 downto 0);
  signal m_arsize  : std_logic_vector(NP_ALL*3-1 downto 0);
  signal m_arburst : std_logic_vector(NP_ALL*2-1 downto 0);
  signal m_rdata   : std_logic_vector(NP_ALL*AXI_DW-1 downto 0)
                     := (others => '0');

  -- THE ELABORATION-TIME HALF OF THE CHECK.  `A_ROWS_IF` is seq_tbl_pkg's, and
  -- the DUT's `y_data` is `ROWS_IF*64` at ITS default.  A mismatch is a port
  -- width error at analysis, which is the cheapest possible failure.
  signal y_we    : std_logic;
  signal y_addr  : std_logic_vector(15 downto 0);
  signal y_data  : std_logic_vector(A_ROWS_IF*64-1 downto 0);
  signal y_mask  : std_logic_vector(A_ROWS_IF-1 downto 0);
  signal y_exp_o : std_logic_vector(31 downto 0);
  signal job_done, job_err : std_logic;

  type dimg_t is array (0 to DWORDS-1) of std_logic_vector(63 downto 0);
  signal dimg : dimg_t := (others => (others => '0'));

  signal nchk, nbad : natural := 0;

  function u32(v : natural) return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(v, 32));
  end function;
begin
  clk <= not clk after 5 ns when not finished else '0';

  -- =====================================================================
  -- The descriptor slave.  Serves DBEATS beats of `dimg` from DESC_ADDR.
  -- =====================================================================
  dslv : process
    variable a : unsigned(ADDR_W-1 downto 0);
    variable n, idx : integer;
    variable b : std_logic_vector(AXI_DW-1 downto 0);
  begin
    d_arready <= '0'; d_rvalid <= '0'; d_rlast <= '0';
    wait until aresetn = '1';
    loop
      d_arready <= '0';
      while d_arvalid = '0' loop wait until rising_edge(clk); end loop;
      a := unsigned(d_araddr);
      n := to_integer(unsigned(d_arlen)) + 1;
      assert d_arburst = "01"
        report "tb_a_geom: descriptor burst IS NOT INCR" severity failure;
      assert a >= to_unsigned(DESC_ADDR, ADDR_W)
        report "tb_a_geom: descriptor fetch below DESC_ADDR" severity failure;
      idx := (to_integer(a) - DESC_ADDR) / PORT_B;
      assert idx + n <= DBEATS
        report "tb_a_geom: descriptor fetch runs past the descriptor"
        severity failure;
      d_arready <= '1'; wait until rising_edge(clk); d_arready <= '0';
      for i in 0 to n-1 loop
        b := (others => '0');
        for j in 0 to WPB-1 loop
          if (idx + i) * WPB + j < DWORDS then
            b((j+1)*64-1 downto j*64) := dimg((idx + i) * WPB + j);
          end if;
        end loop;
        d_rdata  <= b;
        d_rvalid <= '1';
        if i = n-1 then d_rlast <= '1'; else d_rlast <= '0'; end if;
        loop
          wait until rising_edge(clk);
          exit when d_rready = '1';
        end loop;
      end loop;
      d_rvalid <= '0'; d_rlast <= '0';
    end loop;
  end process;

  -- NO GENERIC MAP.  That is the point: every generic is the entity's own
  -- default, so this bench talks to the build the FK33 instantiates rather
  -- than to a set of numbers it typed itself.
  dut : entity work.matvec_int4_desc_axi
    port map(
      s_axi_aclk => clk, s_axi_aresetn => aresetn, m_aclk => clk,
      s_axi_awaddr => awaddr, s_axi_awprot => "000", s_axi_awvalid => awvalid,
      s_axi_awready => awready, s_axi_wdata => wdata, s_axi_wstrb => wstrb,
      s_axi_wvalid => wvalid, s_axi_wready => wready, s_axi_bresp => bresp,
      s_axi_bvalid => bvalid, s_axi_bready => bready,
      s_axi_araddr => araddr_l, s_axi_arprot => "000",
      s_axi_arvalid => arvalid_l, s_axi_arready => arready_l,
      s_axi_rdata => rdata_l, s_axi_rresp => rresp, s_axi_rvalid => rvalid_l,
      s_axi_rready => rready_l,
      d_arvalid => d_arvalid, d_arready => d_arready, d_araddr => d_araddr,
      d_arlen => d_arlen, d_arsize => d_arsize, d_arburst => d_arburst,
      d_rvalid => d_rvalid, d_rready => d_rready, d_rdata => d_rdata,
      d_rlast => d_rlast,
      m_arvalid => m_arvalid, m_arready => m_arready, m_araddr => m_araddr,
      m_arlen => m_arlen, m_arsize => m_arsize, m_arburst => m_arburst,
      m_rvalid => m_rvalid, m_rready => m_rready, m_rdata => m_rdata,
      m_rlast => m_rlast,
      x_we => '0', x_waddr => (others => '0'), x_wdata => (others => '0'),
      x_exp_in => (others => '0'),
      y_we => y_we, y_addr => y_addr, y_data => y_data, y_mask => y_mask,
      y_exp_o => y_exp_o, job_done => job_done, job_err => job_err);

  drv : process
    variable rd : std_logic_vector(31 downto 0);
    variable st : std_logic_vector(31 downto 0);
    variable ec, ei, tmo : integer;

    procedure chk(ok : boolean; what : string) is
    begin
      nchk <= nchk + 1;
      if not ok then
        nbad <= nbad + 1;
        report "tb_a_geom: CHECK FAILED -- " & what severity error;
      end if;
      wait for 0 ns;
    end procedure;

    procedure awr(addr : natural; d : std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      awaddr <= std_logic_vector(to_unsigned(addr, 8));
      wdata  <= d; awvalid <= '1'; wvalid <= '1'; bready <= '1';
      loop
        wait until rising_edge(clk);
        exit when awready = '1' and wready = '1';
      end loop;
      awvalid <= '0'; wvalid <= '0';
      loop
        wait until rising_edge(clk);
        exit when bvalid = '1';
      end loop;
      bready <= '0';
    end procedure;

    procedure ard(addr : natural; d : out std_logic_vector(31 downto 0)) is
    begin
      wait until rising_edge(clk);
      araddr_l  <= std_logic_vector(to_unsigned(addr, 8));
      arvalid_l <= '1'; rready_l <= '1';
      loop
        wait until rising_edge(clk);
        exit when rvalid_l = '1';
      end loop;
      d := rdata_l;
      arvalid_l <= '0'; rready_l <= '0';
      wait until rising_edge(clk);
    end procedure;

    -- The one descriptor this bench builds, with `rows` the only thing that
    -- moves between the two runs.  Everything else is the minimum that gets
    -- S_CHECK as far as the word-1 shape test; see the header.
    -- `npw_f` / `nps_f` default to the build's own counts, so every existing
    -- call is unchanged; the EC_GEOM bracket below is the only caller that
    -- moves them.
    procedure build(rows  : natural;
                    npw_f : natural := NPW;
                    nps_f : natural := NPS) is
      variable w : dimg_t := (others => (others => '0'));
    begin
      -- word 0: op = OP_A_JOB, flags bit 2 (bit 10 of the word) = cb_load, so
      -- the "codebook was never loaded" refusal cannot pre-empt the shape one.
      w(0) := (others => '0');
      w(0)(7 downto 0) := std_logic_vector(to_unsigned(OP_A_JOB, 8));
      w(0)(10) := '1';
      -- word 1: n_rows in the low half, n_cols in the high half.  THIS is the
      -- field under test.
      w(1) := u32(4096) & u32(rows);
      -- word 3: out_mode 0, NPORTS_W, NPORTS_S, pad byte zero
      w(3) := (others => '0');
      w(3)(31 downto 16) := std_logic_vector(to_unsigned(npw_f, 16));
      w(3)(47 downto 32) := std_logic_vector(to_unsigned(nps_f, 16));
      -- word 7 is a pad and must be zero; it already is.
      -- the extension: magic, version, then non-zero w_beats / s_beats
      w(EXT0) := (others => '0');
      w(EXT0)(31 downto 0)  := MV4I_MAGIC;
      w(EXT0)(47 downto 32) := std_logic_vector(to_unsigned(MV4I_DESC_VER, 16));
      w(EXT0 + 1) := u32(1) & u32(1);
      dimg <= w;
      wait for 0 ns;
    end procedure;

    -- Program the pointer, GO, and return (err_code, err_info).  err_code -1
    -- means the run finished or timed out without an error.
    procedure run_desc(ec_o : out integer; ei_o : out integer) is
      variable r : std_logic_vector(31 downto 0);
      variable t : integer := 0;
    begin
      aresetn <= '0';
      for i in 0 to 7 loop wait until rising_edge(clk); end loop;
      aresetn <= '1';
      wait until rising_edge(clk);
      awr(16#00#, u32(DESC_ADDR));
      awr(16#04#, u32(0));
      awr(16#08#, u32(1));
      ec_o := -1; ei_o := -1;
      loop
        ard(16#0C#, r);
        if r(2) = '1' then
          ec_o := to_integer(unsigned(r(11 downto 8)));
          ard(16#10#, r);
          ei_o := to_integer(unsigned(r(15 downto 0)));
          exit;
        end if;
        -- A descriptor that is ACCEPTED stalls forever on the first weight
        -- read, because no weight slave ever answers.  That is a legal
        -- outcome here and the timeout is how it is observed.
        t := t + 1;
        exit when t > 4000;
      end loop;
    end procedure;
  begin
    aresetn <= '0';
    for i in 0 to 7 loop wait until rising_edge(clk); end loop;
    aresetn <= '1';
    wait until rising_edge(clk);

    -- ---- the register-visible geometry --------------------------------
    ard(16#14#, rd);
    chk(rd = MV4I_MAGIC, "ID register is not MV4I");
    ard(16#1C#, rd);
    chk(to_integer(unsigned(rd(23 downto 16))) = A_ROWS_IF,
        "CAPS ROWS_IF is " & integer'image(to_integer(unsigned(rd(23 downto 16))))
        & " and seq_tbl_pkg.A_ROWS_IF is " & integer'image(A_ROWS_IF)
        & ".  The schedule's row windows would not land on a tile.");
    chk(to_integer(unsigned(rd(7 downto 0))) = NPW
        and to_integer(unsigned(rd(15 downto 8))) = NPS
        and to_integer(unsigned(rd(31 downto 24))) = AXI_DW/8,
        "CAPS disagrees with this bench's NPORTS/AXI_DW, so the port widths "
        & "above are sized for a different build");
    ard(16#20#, rd);
    chk(to_integer(unsigned(rd)) = DWORDS,
        "DESC_WORDS is " & integer'image(to_integer(unsigned(rd)))
        & ", the package says " & integer'image(DWORDS));

    -- ---- MAXROWS_BFP, bracketed --------------------------------------
    build(A_MAXROWS_BFP);
    run_desc(ec, ei);
    chk(not (ec = to_integer(unsigned(EC_DESC)) and ei = 1),
        "n_rows = A_MAXROWS_BFP (" & integer'image(A_MAXROWS_BFP)
        & ") was refused at descriptor word 1, so the descriptor plane's "
        & "MAXROWS_BFP is BELOW what seq_tbl_pkg believes.  Every lm_head "
        & "window the schedule emits is too large for this build.");
    report "tb_a_geom: n_rows = " & integer'image(A_MAXROWS_BFP)
         & " -> err_code " & integer'image(ec) & " err_info "
         & integer'image(ei) severity note;

    build(A_MAXROWS_BFP + 1);
    run_desc(ec, ei);
    chk(ec = to_integer(unsigned(EC_DESC)) and ei = 1,
        "n_rows = A_MAXROWS_BFP+1 (" & integer'image(A_MAXROWS_BFP + 1)
        & ") was NOT refused at descriptor word 1 (err_code "
        & integer'image(ec) & " err_info " & integer'image(ei)
        & "), so the descriptor plane's MAXROWS_BFP is ABOVE what "
        & "seq_tbl_pkg believes and the schedule is windowing more than it "
        & "needs to.");
    report "tb_a_geom: n_rows = " & integer'image(A_MAXROWS_BFP + 1)
         & " -> err_code " & integer'image(ec) & " err_info "
         & integer'image(ei) severity note;

    -- ---- NPORTS_W / NPORTS_S, bracketed the same way -------------------
    -- The CAPS read above already compares the numbers, but CAPS is a
    -- register and the thing that decides whether the card runs the schedule
    -- is S_CHECK.  These four let the RTL judge instead, exactly as the
    -- MAXROWS bracket does.  `err_info` is 3 because the refusal names
    -- descriptor WORD 3 (`matvec_int4_desc_axi.vhd:695-698`).
    --
    -- `+1` in the wrong direction is not tested, and that is deliberate: a
    -- descriptor with FEWER bases than the build expects is the same word-3
    -- comparison and would only re-measure this check's own arithmetic.
    build(A_MAXROWS_BFP, npw_f => A_NPORTS_W, nps_f => A_NPORTS_S);
    run_desc(ec, ei);
    chk(ec /= to_integer(unsigned(EC_GEOM)),
        "nsub_w = A_NPORTS_W (" & integer'image(A_NPORTS_W)
        & "), nsub_s = A_NPORTS_S (" & integer'image(A_NPORTS_S)
        & ") was refused EC_GEOM, so the descriptor plane's NPORTS are NOT "
        & "what seq_tbl_pkg believes and EVERY A job in the schedule is "
        & "refused before `start`.");
    report "tb_a_geom: nsub = (" & integer'image(A_NPORTS_W) & ","
         & integer'image(A_NPORTS_S) & ") -> err_code " & integer'image(ec)
         & " err_info " & integer'image(ei) severity note;

    build(A_MAXROWS_BFP, npw_f => A_NPORTS_W + 1, nps_f => A_NPORTS_S);
    run_desc(ec, ei);
    chk(ec = to_integer(unsigned(EC_GEOM)) and ei = 3,
        "nsub_w = A_NPORTS_W+1 (" & integer'image(A_NPORTS_W + 1)
        & ") was NOT refused EC_GEOM at word 3 (err_code "
        & integer'image(ec) & " err_info " & integer'image(ei)
        & "), so this bracket has no teeth and a wrong nsub_w would pass.");
    report "tb_a_geom: nsub_w+1 -> err_code " & integer'image(ec)
         & " err_info " & integer'image(ei) severity note;

    build(A_MAXROWS_BFP, npw_f => A_NPORTS_W, nps_f => A_NPORTS_S + 1);
    run_desc(ec, ei);
    chk(ec = to_integer(unsigned(EC_GEOM)) and ei = 3,
        "nsub_s = A_NPORTS_S+1 (" & integer'image(A_NPORTS_S + 1)
        & ") was NOT refused EC_GEOM at word 3 (err_code "
        & integer'image(ec) & " err_info " & integer'image(ei) & ").");
    report "tb_a_geom: nsub_s+1 -> err_code " & integer'image(ec)
         & " err_info " & integer'image(ei) severity note;

    -- THE VALUE THAT WAS ACTUALLY THERE.  Both schedule generators wrote
    -- (29, 4) into descriptor word 3 until 2026-08-29 and nothing refused it,
    -- because `seq_desc_fetch` only range-checks the field against
    -- NSUB_MAX = 64 and `rtl/llama_top.vhd:2280` binds `matvec_int4`, which
    -- has no descriptor plane at all.  This is the one line in the file that
    -- names the historical defect rather than a neighbourhood of it.
    build(A_MAXROWS_BFP, npw_f => 29, nps_f => 4);
    run_desc(ec, ei);
    chk(ec = to_integer(unsigned(EC_GEOM)) and ei = 3,
        "the pre-2026-08-29 nsub pair (29,4) was NOT refused EC_GEOM at "
        & "word 3 (err_code " & integer'image(ec) & " err_info "
        & integer'image(ei) & ").");
    report "tb_a_geom: nsub = (29,4), the superseded ROWS_IF=58 counts"
         & " -> err_code " & integer'image(ec) & " err_info "
         & integer'image(ei) severity note;

    wait for 0 ns;
    if nbad = 0 then
      report "tb_a_geom RESULT: PASS -- " & integer'image(nchk)
           & " checks, A_ROWS_IF = " & integer'image(A_ROWS_IF)
           & ", A_MAXROWS_BFP = " & integer'image(A_MAXROWS_BFP)
           & ", A_NPORTS_W = " & integer'image(A_NPORTS_W)
           & " and A_NPORTS_S = " & integer'image(A_NPORTS_S)
           & " agree with the descriptor plane's own generic defaults"
        severity note;
    else
      report "tb_a_geom RESULT: FAIL -- " & integer'image(nbad) & " of "
           & integer'image(nchk) & " checks failed" severity failure;
    end if;
    finished <= true;
    wait;
  end process;
end architecture;
