-- sim/tb_attn_kv_axi.vhd -- rtl/attn_kv_axi.vhd against ref/attn_kv_axi_vec.c.
--
-- Two instances of sim/kv_axi_harness.vhd, at the two AXI data widths, because
-- neither width alone reaches every mechanism:
--
--   AXI_DW = 256 (the FK33 HBM SAXI width).  REC_B = 272 is 8.5 beats, so the
--     16-byte record phase alternates with the parity of `pos` and the
--     realignment mux runs on every other record.  A prefetch run of RBUF = 4
--     records is 35 beats and the AXI3 16-beat cap splits it 16 + 16 + 3.
--
--   AXI_DW = 128.  REC_B is exactly 17 beats, so the phase is always 0 -- but
--     a single-record WRITE is 17 beats and splits 16 + 1, which is the only
--     shape in this design that reaches the write-side splitter.
--
-- The two share ONE vector file and one oracle: the records and the memory
-- image do not depend on the bus width, only the transport does.  That is the
-- point of the comparison.
--
-- The oracle is ref/attn_kv_axi_vec.c and it does not model AXI at all; see
-- its header for what that buys and what it therefore cannot see.
--
-- `VECFILE` is passed EXPLICITLY to both instances even though the harness
-- defaults to the same name.  sim/regress.sh discovers a testbench's vector
-- files by scanning THAT FILE for a bare "*.txt" literal, and it does not
-- follow the closure, so a name that lived only in the harness's generic
-- default would never be generated and this bench would fail on "cannot open"
-- inside the shared gate.

library ieee;
use ieee.std_logic_1164.all;

entity tb_attn_kv_axi is
  generic(
    HEAD_DIM : positive := 256;
    KV_BLOCK : positive := 32;
    N_KVH    : positive := 2;
    LAYERS   : positive := 2;
    MAXCTX   : positive := 32;
    STALL    : natural  := 5
  );
end entity;

architecture sim of tb_attn_kv_axi is
  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal fin : std_logic_vector(1 downto 0);
  signal ok  : std_logic_vector(1 downto 0);
  signal running : boolean := true;
begin
  clk <= (not clk) after 5 ns when running else '0';
  rst <= '0' after 40 ns;

  -- the FK33 HBM width: the record phase alternates, the read run splits
  h256 : entity work.kv_axi_harness
    generic map(TAG => "dw256", VECFILE => "attn_kv_axi_vec.txt",
                HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK,
                N_KVH => N_KVH, LAYERS => LAYERS, MAXCTX => MAXCTX,
                AXI_DW => 256, RBUF => 4, MAXB => 16, MAXOUT => 4,
                STALL => STALL)
    port map(clk => clk, rst => rst, fin => fin(0), ok => ok(0));

  -- half the width: no phase, but a single-record write is 17 beats and the
  -- write-side splitter is reached
  h128 : entity work.kv_axi_harness
    generic map(TAG => "dw128", VECFILE => "attn_kv_axi_vec.txt",
                HEAD_DIM => HEAD_DIM, KV_BLOCK => KV_BLOCK,
                N_KVH => N_KVH, LAYERS => LAYERS, MAXCTX => MAXCTX,
                AXI_DW => 128, RBUF => 3, MAXB => 16, MAXOUT => 4,
                STALL => 0)
    port map(clk => clk, rst => rst, fin => fin(1), ok => ok(1));

  P_VERDICT : process
  begin
    wait until fin = "11";
    wait for 100 ns;
    if ok = "11" then
      report "tb_attn_kv_axi: PASS -- 2 AXI widths, records and memory image "
           & "BIT-EXACT against ref/attn_kv_axi_vec.c, no burst crossed 4 KB, "
           & "no ARLEN/AWLEN exceeded the AXI3 16-beat cap, every accepted "
           & "burst completed, and no read reached the current position";
    else
      report "tb_attn_kv_axi: FAIL -- see the mismatches above" severity error;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
