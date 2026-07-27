-- tb/tb_engine_dbg.vhd
-- Probe: run engine_shared with dbg_pos=4 and print the SIM reference values of
-- the debug taps, to compare against the on-silicon readings and locate where the
-- residual stream x first diverges/zeros (engine-context synth bug hunt).
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all; use std.env.all;

entity tb_engine_dbg is end;

architecture sim of tb_engine_dbg is
  constant DIM:integer:=64; constant HIDDEN:integer:=172; constant NHEADS:integer:=8;
  constant NKVH:integer:=4; constant KVDIM:integer:=32; constant HEAD_SIZE:integer:=8;
  constant VOCAB:integer:=512; constant MAXPOS:integer:=24; constant NLAYERS:integer:=5;
  constant NUM_PROMPT:integer:=5; constant N:integer:=24;

  signal clk:std_logic:='0'; signal rst:std_logic:='1'; signal start:std_logic:='0';
  signal token_out,pos_out:integer; signal token_valid,run_done:std_logic;

  signal d_pos:integer := 4;
  signal emb_nz,l0_nz,l4_nz,fin_nz,rms_nz,att_nz:std_logic;
  signal emb_e,l0_e,l4_e,fin_e,rms_e,att_e:integer;
  signal emb_m,l0_m,l4_m,fin_m,rms_m,att_m:std_logic_vector(15 downto 0);
  signal rxchk,rwchk,rxe,rwe,stok:integer; signal rw0:std_logic_vector(15 downto 0);
  signal att_sc,att_sum,att_num:integer;
  -- per-head / per-lane attention probes (the SIM REFERENCE for the board read)
  signal att_sums:std_logic_vector(NHEADS*32-1 downto 0);
  signal amax_l,amax_h,nmax_l,nmax_h:std_logic_vector(31 downto 0);
  signal att_idx:std_logic_vector(15 downto 0);
  -- FAILING-DIVISION probes (attention_ml S_WDIV) -- the SIM REFERENCE for the board
  signal cd_qmag_l,cd_qmag_h,cd_nmag_l,cd_nmag_h:std_logic_vector(31 downto 0);
  signal cd_nsd_l,cd_nsd_h,cd_sum,cd_meta:std_logic_vector(31 downto 0);
  signal l1_qmag_l,l1_qmag_h,l1_nsd_l,l1_nsd_h,l1_sum:std_logic_vector(31 downto 0);
  -- hd0/t1 DIVIDEND (unconditional) + RUNNING-MAX-QUOTIENT capture -- the SIM
  -- REFERENCE for the new 0xDC/0xE0 and 0xA0..0xBC board reads.
  signal l1_nmag_l,l1_nmag_h:std_logic_vector(31 downto 0);
  signal qx_qmag_l,qx_qmag_h,qx_nmag_l,qx_nmag_h:std_logic_vector(31 downto 0);
  signal qx_nsd_l,qx_nsd_h,qx_sum,qx_meta:std_logic_vector(31 downto 0);
  -- INTRA-LAYER-0 STAGE BISECT taps -- the SIM REFERENCE for the 0xA0..0xB8 board
  -- reads (WO -> res1 -> ffn-rms -> W1 -> W3 -> bfp_pack -> W2).
  signal wo_nz,r1_nz,rf_nz,w1_nz,w3_nz,hb_nz,w2_nz:std_logic;
  signal wo_e,r1_e,rf_e,w1_e,w3_e,hb_e,w2_e:integer;
  signal wo_m,r1_m,rf_m,w1_m,w3_m,hb_m,w2_m:std_logic_vector(15 downto 0);

  -- unsigned 64-bit value assembled from the two AXI halves, as a decimal string.
  function u64s(hi,lo:std_logic_vector(31 downto 0)) return string is
    variable v : unsigned(63 downto 0);
  begin
    v := unsigned(hi) & unsigned(lo);
    -- values here are < 2^62, so integer'image of a real-free path is unsafe;
    -- print hex (exact) and let the reader compare bit-for-bit with devmem.
    return "0x"&to_hstring(v);
  end function;

  -- highest set bit of a 64-bit value (msb_pos), 0 for zero -> tells the exponent.
  function msbp(hi,lo:std_logic_vector(31 downto 0)) return integer is
    variable v : unsigned(63 downto 0); variable p : integer := 0;
  begin
    v := unsigned(hi) & unsigned(lo);
    for i in 0 to 63 loop if v(i)='1' then p := i; end if; end loop;
    return p;
  end function;

  -- |num96| as the S_WDIV divide forms it: (ns_dout << WQ) biased by +/- sum/2.
  -- Lets the board read be checked for internal consistency (nmag vs ns_dout/sum).
  function nmag_str(nsd_h,nsd_l,sm:std_logic_vector(31 downto 0)) return string is
    variable n96 : signed(95 downto 0);
    variable a96 : signed(95 downto 0);
    variable s   : signed(63 downto 0);
  begin
    n96 := shift_left(resize(signed(nsd_h & nsd_l), 96), 16);
    s   := resize(signed(sm), 64);
    if n96(95) = '1' then n96 := n96 - resize(shift_right(s, 1), 96);
    else                  n96 := n96 + resize(shift_right(s, 1), 96);
    end if;
    if n96(95) = '1' then a96 := -n96; else a96 := n96; end if;
    return "0x"&to_hstring(unsigned(a96(63 downto 0)));
  end function;

  -- decimal string of a 64-bit unsigned (integer'image is 32-bit only in GHDL).
  function u64dec(v : unsigned(63 downto 0)) return string is
    variable q : unsigned(63 downto 0) := v;
    variable d : integer;
    variable s : string(1 to 20) := (others => ' ');
    variable i : integer := 20;
  begin
    if v = 0 then return "0"; end if;
    while q /= 0 loop
      d := to_integer(q mod 10);
      s(i) := character'val(character'pos('0') + d);
      q := q / 10;
      i := i - 1;
    end loop;
    return s(i+1 to 20);
  end function;

  function u64dec(hi,lo:std_logic_vector(31 downto 0)) return string is
  begin
    return u64dec(unsigned(hi) & unsigned(lo));
  end function;

  function h(nz:std_logic; e:integer; m:std_logic_vector(15 downto 0)) return string is
  begin
    return "nz="&std_logic'image(nz)&" e="&integer'image(e)&
           " m0="&integer'image(to_integer(signed(m)));
  end function;
begin
  clk <= not clk after 5 ns;
  uut: entity work.engine_shared
    generic map(DIM=>DIM,HIDDEN=>HIDDEN,NHEADS=>NHEADS,NKVH=>NKVH,KVDIM=>KVDIM,
      HEAD_SIZE=>HEAD_SIZE,VOCAB=>VOCAB,MAXPOS=>MAXPOS,NLAYERS=>NLAYERS,
      NUM_PROMPT=>NUM_PROMPT,NGEN=>N,DEBUG_TAPS=>true)
    port map(clk=>clk,rst=>rst,start=>start,token_out=>token_out,pos_out=>pos_out,
      token_valid=>token_valid,run_done=>run_done,
      dbg_pos=>d_pos,
      dbg_emb_nz=>emb_nz,dbg_emb_e=>emb_e,dbg_emb_m=>emb_m,
      dbg_l0_nz=>l0_nz,dbg_l0_e=>l0_e,dbg_l0_m=>l0_m,
      dbg_l4_nz=>l4_nz,dbg_l4_e=>l4_e,dbg_l4_m=>l4_m,
      dbg_fin_nz=>fin_nz,dbg_fin_e=>fin_e,dbg_fin_m=>fin_m,
      dbg_rms_nz=>rms_nz,dbg_rms_e=>rms_e,dbg_rms_m=>rms_m,
      dbg_att_nz=>att_nz,dbg_att_e=>att_e,dbg_att_m=>att_m,
      dbg_wo_nz=>wo_nz,dbg_wo_e=>wo_e,dbg_wo_m=>wo_m,
      dbg_r1_nz=>r1_nz,dbg_r1_e=>r1_e,dbg_r1_m=>r1_m,
      dbg_rf_nz=>rf_nz,dbg_rf_e=>rf_e,dbg_rf_m=>rf_m,
      dbg_w1_nz=>w1_nz,dbg_w1_e=>w1_e,dbg_w1_m=>w1_m,
      dbg_w3_nz=>w3_nz,dbg_w3_e=>w3_e,dbg_w3_m=>w3_m,
      dbg_hb_nz=>hb_nz,dbg_hb_e=>hb_e,dbg_hb_m=>hb_m,
      dbg_w2_nz=>w2_nz,dbg_w2_e=>w2_e,dbg_w2_m=>w2_m,
      dbg_rxchk=>rxchk,dbg_rwchk=>rwchk,dbg_rxe=>rxe,dbg_rwe=>rwe,dbg_rw0=>rw0,
      dbg_samptok=>stok,
      dbg_att_sc=>att_sc,dbg_att_sum=>att_sum,dbg_att_num=>att_num,
      dbg_att_sums=>att_sums,
      dbg_att_amax_l=>amax_l,dbg_att_amax_h=>amax_h,
      dbg_att_nmax_l=>nmax_l,dbg_att_nmax_h=>nmax_h,
      dbg_att_idx=>att_idx,
      dbg_cd_qmag_l=>cd_qmag_l,dbg_cd_qmag_h=>cd_qmag_h,
      dbg_cd_nmag_l=>cd_nmag_l,dbg_cd_nmag_h=>cd_nmag_h,
      dbg_cd_nsd_l=>cd_nsd_l,dbg_cd_nsd_h=>cd_nsd_h,
      dbg_cd_sum=>cd_sum,dbg_cd_meta=>cd_meta,
      dbg_l1_qmag_l=>l1_qmag_l,dbg_l1_qmag_h=>l1_qmag_h,
      dbg_l1_nsd_l=>l1_nsd_l,dbg_l1_nsd_h=>l1_nsd_h,
      dbg_l1_sum=>l1_sum,
      dbg_l1_nmag_l=>l1_nmag_l,dbg_l1_nmag_h=>l1_nmag_h,
      dbg_qx_qmag_l=>qx_qmag_l,dbg_qx_qmag_h=>qx_qmag_h,
      dbg_qx_nmag_l=>qx_nmag_l,dbg_qx_nmag_h=>qx_nmag_h,
      dbg_qx_nsd_l=>qx_nsd_l,dbg_qx_nsd_h=>qx_nsd_h,
      dbg_qx_sum=>qx_sum,dbg_qx_meta=>qx_meta);

  process
  begin
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0'; wait until rising_edge(clk);
    start <= '1'; wait until rising_edge(clk); start <= '0';
    wait until run_done = '1'; wait for 1 ns;
    report "SIM taps at dbg_pos="&integer'image(d_pos) severity note;
    report "  embed     : "&h(emb_nz,emb_e,emb_m) severity note;
    report "  L0attRMSo : "&h(rms_nz,rms_e,rms_m) severity note;
    report "  L0attOut  : "&h(att_nz,att_e,att_m) severity note;
    -- ---- INTRA-LAYER-0 STAGE BISECT REFERENCE, in DATAFLOW ORDER -----------
    -- Compare each against the board read at the AXI address shown; the FIRST
    -- one that diverges names the broken stage.
    report "  --- layer-0 stage bisect (dataflow order) ---" severity note;
    report "  [0xA0] WO mm out  : "&h(wo_nz,wo_e,wo_m) severity note;
    report "  [0xA4] residual1  : "&h(r1_nz,r1_e,r1_m) severity note;
    report "  [0xA8] ffn-rmsnorm: "&h(rf_nz,rf_e,rf_m) severity note;
    report "  [0xAC] W1 mm out  : "&h(w1_nz,w1_e,w1_m) severity note;
    report "  [0xB0] W3 mm out  : "&h(w3_nz,w3_e,w3_m) severity note;
    report "  [0xB4] bfp_pack   : "&h(hb_nz,hb_e,hb_m) severity note;
    report "  [0xB8] W2 mm out  : "&h(w2_nz,w2_e,w2_m) severity note;
    report "  --- end stage bisect ---" severity note;
    report "  afterL0   : "&h(l0_nz,l0_e,l0_m) severity note;
    report "  afterL4   : "&h(l4_nz,l4_e,l4_m) severity note;
    report "  afterFin  : "&h(fin_nz,fin_e,fin_m) severity note;
    report "  argmax    : "&integer'image(stok) severity note;
    report "  att SC="&integer'image(att_sc)&" SUM="&integer'image(att_sum)&
           " NUM="&integer'image(att_num) severity note;
    report "  rms_xe="&integer'image(rxe)&" rms_we="&integer'image(rwe)&
           " rms_w0="&integer'image(to_integer(signed(rw0))) severity note;
    -- ---- PER-HEAD / PER-LANE PROBE REFERENCE (L0, this dbg_pos) -------------
    -- NOTE: the per-head sum_l block and the divide-probe block below are NO LONGER
    -- DECODED on AXI -- attention is solved on silicon (divider_rs), so 0xA0..0xBC /
    -- 0xDC / 0xE0 / 0x38 / 0x3C were repurposed for the layer-0 stage bisect taps
    -- above.  These reports are kept as a SIM-ONLY reference; the byte addresses
    -- quoted in them are historical.
    report "PROBES (L0 attention, dbg_pos="&integer'image(d_pos)&") -- SIM ONLY, no AXI slot:" severity note;
    for hh in 0 to NHEADS-1 loop
      report "  sum_l[head "&integer'image(hh)&"] = "&
             integer'image(to_integer(signed(att_sums((hh+1)*32-1 downto hh*32))))&
             "  (0x"&to_hstring(att_sums((hh+1)*32-1 downto hh*32))&")" severity note;
    end loop;
    report "  amax_s      = "&u64s(amax_h,amax_l)&
           "  msb="&integer'image(msbp(amax_h,amax_l))&
           "   [0x24 lo=0x"&to_hstring(amax_l)&" 0x28 hi=0x"&to_hstring(amax_h)&"]"
           severity note;
    report "  max|num_s|  = "&u64s(nmax_h,nmax_l)&
           "  msb="&integer'image(msbp(nmax_h,nmax_l))&
           "   [0x30 lo=0x"&to_hstring(nmax_l)&" 0x34 hi=0x"&to_hstring(nmax_h)&"]"
           severity note;
    report "  0x2C IDX    = 0x"&to_hstring(att_idx)&
           "  amax lane="&integer'image(to_integer(unsigned(att_idx(7 downto 0))))&
           " (head "&integer'image(to_integer(unsigned(att_idx(7 downto 0)))/HEAD_SIZE)&
           ")  nmax lane="&integer'image(to_integer(unsigned(att_idx(15 downto 8))))&
           " (head "&integer'image(to_integer(unsigned(att_idx(15 downto 8)))/HEAD_SIZE)&")"
           severity note;
    -- ---- FAILING-DIVISION REFERENCE (S_WDIV) --------------------------------
    -- In SIM nothing may clamp: seen must be 0 and cnt 0.  The hd0/t1 capture is
    -- unconditional and IS the value silicon has to be compared against.
    report "DIVIDE PROBE (L0 attention, dbg_pos="&integer'image(d_pos)&
           ") -- SIM ONLY, AXI slots repurposed:" severity note;
    report "  [0xBC] META      = 0x"&to_hstring(cd_meta)&
           "   seen="&std_logic'image(cd_meta(31))&
           " cnt="&integer'image(to_integer(unsigned(cd_meta(30 downto 24))))&
           " hd="&integer'image(to_integer(unsigned(cd_meta(23 downto 16))))&
           " t_idx="&integer'image(to_integer(unsigned(cd_meta(15 downto 8))))&
           " lane="&integer'image(to_integer(unsigned(cd_meta(7 downto 0)))) severity note;
    report "  first-clamp qmag = "&u64s(cd_qmag_h,cd_qmag_l)&
           "  msb="&integer'image(msbp(cd_qmag_h,cd_qmag_l))&
           "   [0xA0 lo=0x"&to_hstring(cd_qmag_l)&" 0xA4 hi=0x"&to_hstring(cd_qmag_h)&"]"
           severity note;
    report "  first-clamp nmag = "&u64s(cd_nmag_h,cd_nmag_l)&
           "   [0xA8 lo=0x"&to_hstring(cd_nmag_l)&" 0xAC hi=0x"&to_hstring(cd_nmag_h)&"]"
           severity note;
    report "  first-clamp nsd  = "&u64s(cd_nsd_h,cd_nsd_l)&
           "   [0xB0 lo=0x"&to_hstring(cd_nsd_l)&" 0xB4 hi=0x"&to_hstring(cd_nsd_h)&"]"
           severity note;
    report "  first-clamp sum  = "&integer'image(to_integer(signed(cd_sum)))&
           "   [0xB8 0x"&to_hstring(cd_sum)&"]" severity note;
    report "  hd0/t1 (lane 1) UNCONDITIONAL capture -- compare THIS to silicon:" severity note;
    report "    qmag(pre-clamp) = "&u64s(l1_qmag_h,l1_qmag_l)&
           "  msb="&integer'image(msbp(l1_qmag_h,l1_qmag_l))&
           "   [0x38 lo=0x"&to_hstring(l1_qmag_l)&" 0x3C hi=0x"&to_hstring(l1_qmag_h)&"]"
           severity note;
    report "    ns_dout(num_s)  = "&u64s(l1_nsd_h,l1_nsd_l)&
           " = "&integer'image(to_integer(signed(l1_nsd_l)))&" (as int32)"&
           "   [0xFC lo=0x"&to_hstring(l1_nsd_l)&" 0x10 hi=0x"&to_hstring(l1_nsd_h)&"]"
           severity note;
    report "    sum_l           = "&integer'image(to_integer(signed(l1_sum)))&
           "   [0x00 0x"&to_hstring(l1_sum)&"]" severity note;
    report "    derived nmag    = |ns_dout*2^16 +/- sum/2| = "&
           nmag_str(l1_nsd_h,l1_nsd_l,l1_sum) severity note;
    -- ---- NEW: the DIVIDEND as consumed at hd0/t1 (unconditional) ------------
    report "    nmag (CAPTURED) = "&u64s(l1_nmag_h,l1_nmag_l)&
           " = "&u64dec(l1_nmag_h,l1_nmag_l)&
           "  msb="&integer'image(msbp(l1_nmag_h,l1_nmag_l))&
           "   [0xDC lo=0x"&to_hstring(l1_nmag_l)&" 0xE0 hi=0x"&to_hstring(l1_nmag_h)&"]"
           severity note;
    report "    qmag(dec)       = "&u64dec(l1_qmag_h,l1_qmag_l)&
           "   (must equal nmag/sum_l exactly)" severity note;
    -- ---- NEW: RUNNING-MAX pre-clamp quotient over all 64 divides ------------
    -- This is the division that sets the sticky amax_s (and hence xb_exp), which
    -- is what the wrong attention output exponent is made of.  Lane is NOT
    -- hardcoded -- compare the lane too, it differs sim vs silicon.
    report "RUNNING-MAX QUOTIENT capture (L0 attention, dbg_pos="&
           integer'image(d_pos)&"):" severity note;
    report "  [0xBC] META     = 0x"&to_hstring(qx_meta)&
           "   valid="&std_logic'image(qx_meta(31))&
           " clamp_cnt="&integer'image(to_integer(unsigned(qx_meta(30 downto 24))))&
           " hd="&integer'image(to_integer(unsigned(qx_meta(23 downto 16))))&
           " t_idx="&integer'image(to_integer(unsigned(qx_meta(15 downto 8))))&
           " lane="&integer'image(to_integer(unsigned(qx_meta(7 downto 0)))) severity note;
    report "  [0xA0/A4] qmag  = "&u64s(qx_qmag_h,qx_qmag_l)&
           " = "&u64dec(qx_qmag_h,qx_qmag_l)&
           "  msb="&integer'image(msbp(qx_qmag_h,qx_qmag_l)) severity note;
    report "  [0xA8/AC] nmag  = "&u64s(qx_nmag_h,qx_nmag_l)&
           " = "&u64dec(qx_nmag_h,qx_nmag_l)&
           "  msb="&integer'image(msbp(qx_nmag_h,qx_nmag_l)) severity note;
    report "  [0xB0/B4] nsd   = "&u64s(qx_nsd_h,qx_nsd_l)&
           " = "&integer'image(to_integer(signed(qx_nsd_l)))&" (as int32)" severity note;
    report "  [0xB8]    sum_l = "&integer'image(to_integer(signed(qx_sum)))&
           "   (0x"&to_hstring(qx_sum)&")" severity note;
    report "  derived nmag from nsd/sum = "&nmag_str(qx_nsd_h,qx_nsd_l,qx_sum)&
           "   (must equal the CAPTURED nmag above)" severity note;
    finish;
  end process;
end architecture;
