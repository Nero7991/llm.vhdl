-- sim/tb_gdn_exp_capture.vhd
-- rtl/gdn_exp_capture.vhd against an independent behavioural model.
--
-- WHY THE GOLDEN IS IN THE TESTBENCH HERE, and not a C generator like every
-- other B unit: this unit does no arithmetic. It is bookkeeping -- a shift
-- register per (layer, segment) and a saturating counter -- so a C reference
-- would add a file format and a build step without adding independence. What
-- independence requires is that the model NOT share machinery with the DUT,
-- and it does not: the DUT is a block RAM plus a read-modify-write FSM, the
-- model below is a plain VHDL array updated combinationally.
--
-- The cases that matter are the tap-masking ones the spec's test list calls
-- for (tk = 0, 1, 2), because tvalid is what stops the conv from folding an
-- exponent for a token that does not exist -- the masked-operand rule that
-- has already produced three separate defects in this subsystem.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use ieee.math_real.all;

entity tb_gdn_exp_capture is
  generic( LAYERS : positive := 4;
           SEGS   : positive := 3;
           K      : positive := 4 );
end entity;

architecture sim of tb_gdn_exp_capture is
  constant NENT : integer := LAYERS * SEGS;

  signal clk : std_logic := '0';
  signal rst : std_logic := '1';
  signal seq_rst : std_logic := '0';

  signal cap_req   : std_logic := '0';
  signal cap_layer : integer range 0 to LAYERS-1 := 0;
  signal cap_seg   : integer range 0 to SEGS-1 := 0;
  signal cap_exp   : signed(7 downto 0) := (others => '0');
  signal cap_ready : std_logic;

  signal rd_req   : std_logic := '0';
  signal rd_layer : integer range 0 to LAYERS-1 := 0;
  signal rd_seg   : integer range 0 to SEGS-1 := 0;
  signal rd_ack   : std_logic;
  signal e_t      : std_logic_vector(K*8-1 downto 0);
  signal tvalid   : std_logic_vector(K-1 downto 0);

  signal running : boolean := true;

  -- independent model
  type tap_t is array (0 to NENT-1, 0 to K-1) of integer;
  type cnt_t is array (0 to NENT-1) of integer;
begin
  clk <= not clk after 5 ns when running else '0';

  dut : entity work.gdn_exp_capture
    generic map ( LAYERS => LAYERS, SEGS => SEGS, K => K )
    port map ( clk => clk, rst => rst, seq_rst => seq_rst,
               cap_req => cap_req, cap_layer => cap_layer, cap_seg => cap_seg,
               cap_exp => cap_exp, cap_ready => cap_ready,
               rd_req => rd_req, rd_layer => rd_layer, rd_seg => rd_seg,
               rd_ack => rd_ack, e_t => e_t, tvalid => tvalid );

  stim : process
    variable m_tap : tap_t := (others => (others => 0));
    variable m_cnt : cnt_t := (others => 0);
    variable nerr  : integer := 0;
    variable seed1 : positive := 20260827;
    variable seed2 : positive := 7;
    variable r     : real;
    variable ev    : integer;
    variable a     : integer;
    variable want_mask : std_logic_vector(K-1 downto 0);

    procedure do_capture(l : integer; s : integer; e : integer;
                         signal cr : out std_logic;
                         signal cl : out integer; signal cs : out integer;
                         signal ce : out signed(7 downto 0)) is
    begin
      cr <= '1'; cl <= l; cs <= s; ce <= to_signed(e, 8);
      wait until rising_edge(clk);
      cr <= '0';
      -- cap_ready drops for the read-modify-write; wait it out
      wait until rising_edge(clk);
      while cap_ready /= '1' loop wait until rising_edge(clk); end loop;
    end procedure;
  begin
    rst <= '1';
    wait until rising_edge(clk); wait until rising_edge(clk);
    rst <= '0';
    wait until rising_edge(clk);

    -- ---- token-by-token, so tk = 0, 1, 2 masking is exercised in order ----
    for tok in 0 to 5 loop
      for l in 0 to LAYERS-1 loop
        for s in 0 to SEGS-1 loop
          uniform(seed1, seed2, r);
          ev := integer(r * 200.0) - 100;          -- int8 range, both signs
          a  := l * SEGS + s;

          do_capture(l, s, ev, cap_req, cap_layer, cap_seg, cap_exp);

          -- model: shift down, newest into tap K-1
          for t in 0 to K-2 loop
            m_tap(a, t) := m_tap(a, t+1);
          end loop;
          m_tap(a, K-1) := ev;
          if m_cnt(a) < K then m_cnt(a) := m_cnt(a) + 1; end if;

          -- read it back
          rd_req <= '1'; rd_layer <= l; rd_seg <= s;
          wait until rising_edge(clk);
          rd_req <= '0';
          while rd_ack /= '1' loop wait until rising_edge(clk); end loop;

          -- ONLY the taps tvalid declares valid are compared, and that is a
          -- correctness statement about the DESIGN, not a convenience.  The
          -- word memory is deliberately not cleared (see the unit header), so
          -- before an entry has had K captures its older taps hold whatever
          -- the RAM powers up with -- 'U' in simulation, arbitrary in
          -- hardware.  tvalid is what makes that safe.
          --
          -- The first version of this loop compared all K taps and PASSED, by
          -- accident: to_integer of a 'U' vector returns 0 with a metavalue
          -- warning, and the model's unwritten taps were also 0.  The check
          -- was reading the warning as agreement.  Comparing an invalid tap
          -- is therefore not merely unnecessary, it is a test that silently
          -- succeeds for the wrong reason.
          for t in 0 to K-1 loop
            if tvalid(t) = '1'
            and to_integer(signed(e_t((t+1)*8-1 downto t*8))) /= m_tap(a, t) then
              report "tok " & integer'image(tok) & " layer " & integer'image(l)
                   & " seg " & integer'image(s) & " tap " & integer'image(t)
                   & ": e_t got "
                   & integer'image(to_integer(signed(e_t((t+1)*8-1 downto t*8))))
                   & " want " & integer'image(m_tap(a, t)) severity error;
              nerr := nerr + 1;
            end if;
          end loop;

          want_mask := (others => '0');
          for t in 0 to K-1 loop
            if t >= K - m_cnt(a) then want_mask(t) := '1'; end if;
          end loop;
          if tvalid /= want_mask then
            report "tok " & integer'image(tok) & " layer " & integer'image(l)
                 & " seg " & integer'image(s) & ": tvalid mismatch (count "
                 & integer'image(m_cnt(a)) & ")" severity error;
            nerr := nerr + 1;
          end if;

          -- The tk = 0 case is the one the masked-operand rule keeps breaking
          -- on, so it is asserted explicitly rather than left to the compare.
          if tok = 0 then
            -- Written as an explicit compare, not an aggregate with `others`:
            -- the target is an unconstrained comparison context, where VHDL
            -- rejects `others`.
            for t in 0 to K-1 loop
              if (t = K-1 and tvalid(t) /= '1')
              or (t /= K-1 and tvalid(t) /= '0') then
                report "at tk = 0 exactly one tap must be valid, the current one"
                  severity error;
                nerr := nerr + 1;
              end if;
            end loop;
          end if;
        end loop;
      end loop;
    end loop;

    -- ---- seq_rst clears validity but not the words -------------------------
    seq_rst <= '1'; wait until rising_edge(clk); seq_rst <= '0';
    wait until rising_edge(clk);
    rd_req <= '1'; rd_layer <= 0; rd_seg <= 0;
    wait until rising_edge(clk); rd_req <= '0';
    while rd_ack /= '1' loop wait until rising_edge(clk); end loop;
    if tvalid /= (tvalid'range => '0') then
      report "seq_rst must clear every tap-validity bit" severity error;
      nerr := nerr + 1;
    end if;

    if nerr = 0 then
      report "tb_gdn_exp_capture: PASS -- 6 tokens x "
           & integer'image(LAYERS) & " layers x " & integer'image(SEGS)
           & " segments, e_t and tvalid exact" severity note;
    else
      report "tb_gdn_exp_capture: FAIL -- " & integer'image(nerr)
           & " mismatches" severity failure;
    end if;
    running <= false;
    wait;
  end process;
end architecture;
