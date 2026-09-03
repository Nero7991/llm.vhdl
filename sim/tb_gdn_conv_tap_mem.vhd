-- sim/tb_gdn_conv_tap_mem.vhd -- the causal conv history, checked against the
-- TOKEN HISTORY and not against a mirror of the implementation.
--
-- `rtl/gdn_conv_tap_mem.vhd` keeps KCONV-1 columns of the whole qkv width per
-- GDN layer and rotates them rather than shifting.  The rotation is the part
-- that can be wrong in a way nothing else notices: every individual read and
-- write can be correct while the taps come back in the wrong ORDER, or one
-- token stale, and `gdn_conv` would then compute a plausible wrong number.
--
-- SO THE ORACLE IS THE TOKEN SEQUENCE, NOT THE SLOT ARITHMETIC.  The bench
-- knows only that at token T the memory must hand back columns T-KCONV+1 ..
-- T-1, oldest first, and zeros for anything before token 0.  It computes that
-- from `colval(token, channel)` directly.  It does NOT model `phase`, and it
-- does not know which slot anything lives in -- a bench that mirrored the slot
-- arithmetic would agree with a wrong implementation that used the same
-- arithmetic, which is the `m7 mutant` failure this project has on record: a
-- packer plus a reversed decoder passed an entire self-test suite.
--
-- THE READ MUST BE ONE EDGE, NOT ZERO AND NOT TWO.  `gdn_block`:269-272 says
-- "cv_x/cv_w must be valid in the cycle AFTER the one in which cv_ren is
-- high, i.e. exactly what a registered-output BRAM does."  Both directions are
-- checked: the value must NOT be there before the edge, and it must be there
-- after it.  A bench that only checked the second would pass against a
-- combinational memory, which is the wrong primitive.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_conv_tap_mem is
  generic(
    KCONV      : positive := 4;
    CONV_LANES : positive := 2;
    KEY_CH     : positive := 4;
    VAL_CH     : positive := 8;
    NTOK       : positive := 6
  );
end entity;

architecture sim of tb_gdn_conv_tap_mem is
  constant NTAP : positive := KCONV - 1;
  constant QKVN : positive := 2*KEY_CH + VAL_CH;
  constant NGRP : positive := QKVN / CONV_LANES;
  constant GW   : positive := CONV_LANES * 16;
  constant WORDS: positive := NTAP * QKVN;

  signal clk : std_logic := '0';

  signal r_seg : integer range 0 to 2 := 0;
  signal r_grp : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal r_x   : std_logic_vector(NTAP*GW-1 downto 0);

  signal w_en   : std_logic := '0';
  signal w_seg  : integer range 0 to 2 := 0;
  signal w_grp  : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal w_data : std_logic_vector(GW-1 downto 0) := (others => '0');

  signal tok_adv : std_logic := '0';

  signal m_r_en   : std_logic := '0';
  signal m_r_addr : natural range 0 to WORDS-1 := 0;
  signal m_r_data : std_logic_vector(15 downto 0);
  signal m_w_en   : std_logic := '0';
  signal m_w_addr : natural range 0 to WORDS-1 := 0;
  signal m_w_data : std_logic_vector(15 downto 0) := (others => '0');

  signal n_chk, n_bad : natural := 0;
  signal n_tap  : natural := 0;   -- tap-order checks, the point of the file
  signal n_edge : natural := 0;   -- proofs the read is NOT combinational

  -- THE VALUE OF CHANNEL `ch` AT TOKEN `t`.  The bench's whole model.
  -- THE PARAMETER IS `tok`, NOT `t`, AND THAT IS NOT COSMETIC.  **VHDL
  -- identifiers are CASE-INSENSITIVE**, so a `for t in ...` nested inside a
  -- `for T in ...` is the SAME name and silently shadows the outer token
  -- index.  MEASURED here: all 48 tap-order checks failed, the DUT was
  -- correct, and the only warning was one `-Whide` line that reads like
  -- pedantry: `declaration of "t" hides constant "t"`.  The inner loops below
  -- use `k` for the same reason.
  function colval(tok : integer; ch : natural) return std_logic_vector is
  begin
    if tok < 0 then
      return x"0000";   -- older than the sequence: zero, not a stand-in
    end if;
    return std_logic_vector(to_unsigned(
      ((tok*1013 + ch*37 + 11) mod 65536), 16));
  end function;

  -- The first channel of segment `seg`, group `grp`.  q | k | v, the order
  -- llama_top's `cvdata_p` and `seq_opdec`'s MSEG mechanism both use.
  function chan_of(seg : integer; grp : natural; ln : natural)
    return natural is
  begin
    if seg = 0 then return grp*CONV_LANES + ln;
    elsif seg = 1 then return KEY_CH + grp*CONV_LANES + ln;
    else return 2*KEY_CH + grp*CONV_LANES + ln; end if;
  end function;

  function grps_in(seg : integer) return natural is
  begin
    if seg = 2 then return VAL_CH/CONV_LANES; else return KEY_CH/CONV_LANES; end if;
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_conv_tap_mem
    -- "auto" here and "block" on the card.  `ram_style` is a SYNTHESIS
    -- attribute; GHDL ignores it, so this bench runs identically either way
    -- and is set to "auto" so the row does not read as though it exercised
    -- the BRAM configuration, WHICH IT DOES NOT.
    generic map(KCONV => KCONV, CONV_LANES => CONV_LANES,
                KEY_CH => KEY_CH, VAL_CH => VAL_CH, STYLE => "auto")
    port map(clk => clk,
             r_seg => r_seg, r_grp => r_grp, r_x => r_x,
             w_en => w_en, w_seg => w_seg, w_grp => w_grp, w_data => w_data,
             tok_adv => tok_adv,
             m_r_en => m_r_en, m_r_addr => m_r_addr, m_r_data => m_r_data,
             m_w_en => m_w_en, m_w_addr => m_w_addr, m_w_data => m_w_data);

  stim : process is
    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk <= n_chk + 1;
      if not cond then
        n_bad <= n_bad + 1;
        report "tb_gdn_conv_tap_mem: " & msg severity error;
      end if;
      wait for 0 ns;
    end procedure;

    -- Drive an address, cross ONE rising edge, settle the deltas.  A real
    -- 1 ns rather than a counted `wait for 0 ns`: a delta count encodes how
    -- many concurrent assignments the signal happens to pass through inside
    -- the DUT, and adding one relay there then shifts every read by one
    -- address.  Measured on the sibling exponent store the same day.
    procedure unit_read(seg : integer; grp : natural) is
    begin
      r_seg <= seg; r_grp <= grp;
      tick;
      wait for 1 ns;
    end procedure;

    procedure unit_write(seg : integer; grp : natural;
                         d : std_logic_vector) is
    begin
      w_en <= '1'; w_seg <= seg; w_grp <= grp; w_data <= d;
      tick;
      w_en <= '0';
    end procedure;

    variable col : std_logic_vector(GW-1 downto 0);
    variable ch  : natural;
    variable ok  : boolean;
    variable before : std_logic_vector(NTAP*GW-1 downto 0);
  begin
    tick(2);

    -- ================= tokens =========================================
    for T in 0 to NTOK-1 loop
      -- ---- read every group of every segment and check the ORDER --------
      for seg in 0 to 2 loop
        for grp in 0 to grps_in(seg)-1 loop
          unit_read(seg, grp);
          ok := true;
          for k in 0 to NTAP-1 loop
            for ln in 0 to CONV_LANES-1 loop
              ch := chan_of(seg, grp, ln);
              if r_x(k*GW + (ln+1)*16 - 1 downto k*GW + ln*16)
                 /= colval(T - NTAP + k, ch) then
                ok := false;
              end if;
            end loop;
          end loop;
          n_tap <= n_tap + 1;
          chk(ok, "token " & integer'image(T) & " seg " & integer'image(seg)
                & " grp " & integer'image(grp)
                & ": the stored taps are not columns "
                & integer'image(T-NTAP) & ".." & integer'image(T-1)
                & " oldest first; got " & to_hstring(r_x));
        end loop;
      end loop;

      -- ---- write THIS token's column -----------------------------------
      for seg in 0 to 2 loop
        for grp in 0 to grps_in(seg)-1 loop
          for ln in 0 to CONV_LANES-1 loop
            col((ln+1)*16-1 downto ln*16) := colval(T, chan_of(seg, grp, ln));
          end loop;
          unit_write(seg, grp, col);
        end loop;
      end loop;

      -- ---- the rotation, once per token --------------------------------
      tok_adv <= '1'; tick; tok_adv <= '0';
    end loop;

    -- ================= the read is ONE edge, not zero ==================
    -- Drive a DIFFERENT address and check the data has NOT moved yet.  This
    -- is the check that discriminates against a combinational memory; the
    -- loops above pass against one.
    r_seg <= 2; r_grp <= 0;
    tick; wait for 1 ns;
    before := r_x;
    r_seg <= 2; r_grp <= 1;
    wait for 1 ns;                     -- no rising edge crossed
    n_edge <= n_edge + 1;
    chk(r_x = before,
        "the unit read is COMBINATIONAL: the data moved with no clock edge");
    tick; wait for 1 ns;
    n_edge <= n_edge + 1;
    chk(r_x /= before or NTAP = 0,
        "the unit read did not follow the address after one edge");

    -- ================= the mover port round-trips the layer =============
    -- Slot-major: addr = slot*QKVN + channel, with slot 0 the OLDEST.  After
    -- NTOK tokens and NTOK advances the phase is back where the model says,
    -- so the bench can predict every word from the token history alone.
    m_r_en <= '1';
    for a in 0 to WORDS-1 loop
      m_r_addr <= a;
      tick; wait for 1 ns;
      chk(m_r_data = colval(NTOK - NTAP + (a / QKVN), a mod QKVN),
          "mover read at " & integer'image(a) & " got "
          & to_hstring(m_r_data) & " want "
          & to_hstring(colval(NTOK - NTAP + (a / QKVN), a mod QKVN)));
    end loop;

    m_r_en <= '0';

    -- ---- write a fresh layer through the mover, read it back as taps ----
    for a in 0 to WORDS-1 loop
      m_w_en <= '1'; m_w_addr <= a;
      m_w_data <= std_logic_vector(to_unsigned((a*7 + 3) mod 65536, 16));
      tick;
    end loop;
    m_w_en <= '0';
    tick;

    for seg in 0 to 2 loop
      for grp in 0 to grps_in(seg)-1 loop
        unit_read(seg, grp);
        ok := true;
        for k in 0 to NTAP-1 loop
          for ln in 0 to CONV_LANES-1 loop
            ch := chan_of(seg, grp, ln);
            -- The rotation is NOT the identity here: NTOK advances have moved
            -- `phase`, and slot-major HBM order is OLDEST first, so tap k is
            -- slot k only if the bench's model of "oldest" agrees with the
            -- DUT's.  That agreement is the property.
            if r_x(k*GW + (ln+1)*16 - 1 downto k*GW + ln*16)
               /= std_logic_vector(to_unsigned(((k*QKVN + ch)*7 + 3) mod 65536,
                                               16)) then
              ok := false;
            end if;
          end loop;
        end loop;
        chk(ok, "after a mover LOAD, seg " & integer'image(seg) & " grp "
              & integer'image(grp) & " did not read back slot-major order; "
              & "got " & to_hstring(r_x));
      end loop;
    end loop;

    -- ================= the mover wins a simultaneous write ==============
    m_w_en <= '1'; m_w_addr <= 0; m_w_data <= x"BEEF";
    w_en <= '1'; w_seg <= 0; w_grp <= 0; w_data <= (others => '1');
    tick;
    m_w_en <= '0'; w_en <= '0';
    tick;
    m_r_en <= '1'; m_r_addr <= 0; tick; wait for 1 ns;
    chk(m_r_data = x"BEEF",
        "the mover port did not win a simultaneous write: got "
        & to_hstring(m_r_data));

    tick(2);
    report "tb_gdn_conv_tap_mem: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " tap-order=" & integer'image(n_tap)
         & " read-latency=" & integer'image(n_edge)
         & " tokens=" & integer'image(NTOK) severity note;

    -- A run with fewer tokens than the kernel never sees a full history and
    -- checks the interesting case not at all.
    assert NTOK > KCONV
      report "tb_gdn_conv_tap_mem: FAIL, NTOK <= KCONV never fills the "
           & "history, so the rotation is UNTESTED."
      severity failure;
    assert n_tap > 0 and n_edge > 0
      report "tb_gdn_conv_tap_mem: FAIL, the tap order or the read latency "
           & "was never checked."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_conv_tap_mem RESULT: PASS -- " & integer'image(n_chk)
           & " checks, of which " & integer'image(n_tap)
           & " confirmed the taps are columns T-" & integer'image(NTAP)
           & "..T-1 oldest first across " & integer'image(NTOK)
           & " tokens." severity note;
    else
      report "tb_gdn_conv_tap_mem RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
