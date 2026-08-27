-- sim/tb_b_audit_ser_handshake.vhd
--
-- AUDIT ARTEFACT, not a correctness testbench.  Written for
-- docs/debugging/2026-08-27_B-interface-audit.md, finding B-1.
--
-- WHAT IT SHOWS.  gdn_emit_chain's S_SER loop advances `ser_j` on `ye_ready`
-- alone, without checking that a transfer actually happened.  In the FIRST
-- cycle of S_SER, `ye_valid` is still '0' (it was cleared at the end of the
-- previous head), so that first advance is a PHANTOM one whose only job is to
-- compensate for the one-cycle registration delay on `ye_o`.  If `ye_ready`
-- happens to be LOW in that first cycle, the phantom advance does not happen,
-- the whole element sequence shifts by one, and element 0 of that head is
-- transferred TWICE -- DIM+1 elements for a head that has DIM.
--
-- The producer process below is a VERBATIM transcription of the S_SER branch
-- of rtl/gdn_emit_chain.vhd (the `ser_j` / `ye_valid` / `ye_hfirst` / `ye_o`
-- assignments and their guard), driving the REAL rtl/gdn_y_emit.vhd.  No RTL
-- is modified.  HEAD_GAP models the S_IDLE + S_GATE + S_RMS time the real
-- chain spends between heads; it is the only knob.
--
--   HEAD_GAP small  -> the fill outruns y_emit's two reduce passes, in_ready
--                      falls at a block boundary, and the duplicate appears.
--   HEAD_GAP large  -> the reduce keeps up, in_ready never falls, DIM elements
--                      per head exactly.  This is the shipped configuration.
--
-- Bounded by construction: the stimulus is a fixed number of heads and the
-- run is driven with an explicit --stop-time.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;

entity tb_b_audit_ser_handshake is
  generic(
    HEADS    : positive := 4;
    DIM      : positive := 16;
    BLOCKS   : positive := 3;
    -- Idle cycles between one head's last element and the next head's S_SER.
    HEAD_GAP : natural  := 0
  );
end entity;

architecture sim of tb_b_audit_ser_handshake is

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';

  signal ye_valid  : std_logic := '0';
  signal ye_ready  : std_logic;
  signal ye_hfirst : std_logic := '0';
  signal ye_o      : signed(15 downto 0) := (others => '0');
  signal ye_z      : signed(15 downto 0) := (others => '0');
  signal ye_e      : signed(7 downto 0)  := (others => '0');

  signal o_valid : std_logic;
  signal o_mant  : signed(15 downto 0);
  signal o_last  : std_logic;
  signal y_exp   : signed(7 downto 0);
  signal ye_done : std_logic;
  signal o_sat   : std_logic;

  -- producer state, transcribed from gdn_emit_chain's S_SER
  type pst_t is (P_GAP, P_SER);
  signal pst   : pst_t := P_GAP;
  signal ser_j : integer range 0 to DIM := 0;
  signal gapc  : integer range 0 to 4095 := 0;
  signal head  : integer range 0 to HEADS := 0;
  signal blk   : integer range 0 to BLOCKS := 0;

  -- observation
  signal xfer_head : integer := 0;   -- transfers within the current head
  signal worst_head : integer := 0;  -- largest per-head transfer count seen
  signal dup_heads  : integer := 0;  -- heads that moved more than DIM elements
  signal ready_low_at_entry : integer := 0;
  signal running : boolean := true;

begin

  clk <= not clk after 0.5 ns when running else '0';

  dut : entity work.gdn_y_emit
    generic map ( HEADS => HEADS, DIM => DIM )
    port map ( clk => clk, rst => rst,
               in_valid => ye_valid, in_ready => ye_ready,
               in_hfirst => ye_hfirst,
               in_o => ye_o, in_z => ye_z, in_e => ye_e,
               o_valid => o_valid, o_mant => o_mant, o_last => o_last,
               y_exp => y_exp, done => ye_done, o_sat => o_sat );

  rst <= '1', '0' after 5 ns;

  -- ---------------------------------------------------------------------
  -- The producer.  The P_SER branch is gdn_emit_chain.vhd's S_SER, copied.
  -- ---------------------------------------------------------------------
  producer : process(clk)
  begin
    if rising_edge(clk) then
      if rst = '1' then
        pst <= P_GAP; ser_j <= 0; gapc <= 0; head <= 0; blk <= 0;
        ye_valid <= '0'; ye_hfirst <= '0';
      elsif blk < BLOCKS then
        case pst is

          when P_GAP =>
            if gapc >= HEAD_GAP then
              gapc  <= 0;
              ser_j <= 0;
              -- The instant the real chain enters S_SER.  Recorded because
              -- ye_ready being LOW here is the whole precondition.
              if ye_ready = '0' then
                ready_low_at_entry <= ready_low_at_entry + 1;
              end if;
              pst <= P_SER;
            else
              gapc <= gapc + 1;
            end if;

          when P_SER =>
            if ser_j < DIM then
              ye_valid <= '1';
              if ser_j = 0 then ye_hfirst <= '1'; else ye_hfirst <= '0'; end if;
              ye_o <= to_signed(ser_j + 1, 16);
              ye_z <= to_signed(1, 16);
              ye_e <= to_signed(0, 8);
              if ye_ready = '1' then
                ser_j <= ser_j + 1;
              end if;
            else
              ye_valid  <= '0';
              ye_hfirst <= '0';
              if head = HEADS-1 then
                head <= 0;
                blk  <= blk + 1;
              else
                head <= head + 1;
              end if;
              pst <= P_GAP;
            end if;

        end case;
      else
        ye_valid <= '0';
      end if;
    end if;
  end process;

  -- ---------------------------------------------------------------------
  -- Count actual valid/ready transfers per head.
  -- ---------------------------------------------------------------------
  counter : process(clk)
  begin
    if rising_edge(clk) and rst = '0' then
      if ye_valid = '1' and ye_ready = '1' then
        xfer_head <= xfer_head + 1;
        if xfer_head + 1 > worst_head then
          worst_head <= xfer_head + 1;
        end if;
      elsif ye_valid = '0' and xfer_head > 0 then
        if xfer_head > DIM then
          dup_heads <= dup_heads + 1;
        end if;
        xfer_head <= 0;
      end if;
    end if;
  end process;

  report_p : process
  begin
    wait until rst = '0';
    while blk < BLOCKS loop
      wait until rising_edge(clk);
    end loop;
    for i in 0 to 40 loop wait until rising_edge(clk); end loop;
    report "tb_b_audit_ser_handshake: HEAD_GAP=" & integer'image(HEAD_GAP)
         & "  DIM=" & integer'image(DIM)
         & "  heads that moved more than DIM elements: "
         & integer'image(dup_heads)
         & "  worst per-head transfer count: " & integer'image(worst_head)
         & "  S_SER entries with ye_ready low: "
         & integer'image(ready_low_at_entry);
    assert dup_heads = 0
      report "tb_b_audit_ser_handshake: the S_SER loop delivered MORE than DIM "
           & "elements for at least one head.  gdn_y_emit's element-to-head "
           & "alignment is now permanently offset."
      severity note;
    running <= false;
    wait;
  end process;

end architecture;
