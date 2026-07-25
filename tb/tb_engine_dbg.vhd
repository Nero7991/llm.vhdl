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
      dbg_rxchk=>rxchk,dbg_rwchk=>rwchk,dbg_rxe=>rxe,dbg_rwe=>rwe,dbg_rw0=>rw0,
      dbg_samptok=>stok,
      dbg_att_sc=>att_sc,dbg_att_sum=>att_sum,dbg_att_num=>att_num);

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
    report "  afterL0   : "&h(l0_nz,l0_e,l0_m) severity note;
    report "  afterL4   : "&h(l4_nz,l4_e,l4_m) severity note;
    report "  afterFin  : "&h(fin_nz,fin_e,fin_m) severity note;
    report "  argmax    : "&integer'image(stok) severity note;
    report "  att SC="&integer'image(att_sc)&" SUM="&integer'image(att_sum)&
           " NUM="&integer'image(att_num) severity note;
    report "  rms_xe="&integer'image(rxe)&" rms_we="&integer'image(rwe)&
           " rms_w0="&integer'image(to_integer(signed(rw0))) severity note;
    finish;
  end process;
end architecture;
