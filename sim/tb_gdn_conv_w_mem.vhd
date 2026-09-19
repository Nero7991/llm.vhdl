-- sim/tb_gdn_conv_w_mem.vhd -- the resident conv WEIGHTS, checked against
-- the image the mover wrote and not against a mirror of the bank arithmetic.
--
-- `rtl/gdn_conv_w_mem.vhd` holds one layer's `[KCONV][QKVN]` conv weights,
-- written by the store's fourth mover phase as flat words `t*QKVN + ch` and
-- read by the conv unit one (segment, group) at a time as `cv_w`.  The thing
-- that can be silently wrong is the ORDER: a memory that stores every word
-- and hands back tap 3's weight as tap 0's computes a plausible wrong number,
-- and every individual read and write is correct while it does so.
--
-- SO THE ORACLE IS THE IMAGE, NOT THE SLOT ARITHMETIC.  The bench knows only
-- that word `t*QKVN + ch` of the image is the weight of tap t, channel ch,
-- and that `cv_w`'s bit slice `(t*CONV_LANES + ln)*16 +: 16` must be that
-- word for channel `seg_base + grp*CONV_LANES + ln`.  It does not know which
-- bank anything lives in.
--
-- THE READ MUST BE ONE EDGE, NOT ZERO.  `gdn_block`:269-272: "cv_x/cv_w must
-- be valid in the cycle AFTER the one in which cv_ren is high".  Both
-- directions are checked: the value must NOT be there before the edge, and
-- it must be there after it.  A bench that only checked the second would
-- pass against a combinational memory, which is the wrong primitive.
--
-- CHECKS ARE COUNTED IN VARIABLES.  A signal incremented twice in one delta
-- keeps only the last value; MEASURED elsewhere in this repository as a
-- bench reporting 13 checks for a body containing 60.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;
use std.env.finish;

entity tb_gdn_conv_w_mem is
  generic(
    KCONV      : positive := 4;
    CONV_LANES : positive := 2;
    KEY_CH     : positive := 4;
    VAL_CH     : positive := 8;
    NIMG       : positive := 3    -- images loaded in turn; each must replace
  );
end entity;

architecture sim of tb_gdn_conv_w_mem is
  constant QKVN  : positive := 2*KEY_CH + VAL_CH;
  constant GW    : positive := CONV_LANES * 16;
  constant WORDS : positive := KCONV * QKVN;

  signal clk : std_logic := '0';

  signal r_seg : integer range 0 to 2 := 0;
  signal r_grp : natural range 0 to VAL_CH/CONV_LANES-1 := 0;
  signal r_w   : std_logic_vector(KCONV*GW-1 downto 0);

  signal m_w_en   : std_logic := '0';
  signal m_w_addr : natural range 0 to WORDS-1 := 0;
  signal m_w_data : std_logic_vector(15 downto 0) := (others => '0');

  -- Word `w` of image `img`.  Distinct in every (img, t, ch), and NOT a
  -- function of the bank index, so a swapped tap and a swapped lane both
  -- produce a value the bench can name.  The parameter is `tok`-style
  -- spelling for the same reason tb_gdn_conv_tap_mem gives: VHDL is
  -- case-insensitive and `t` inside a `for T` loop is the same name.
  function wval(img : natural; tap : natural; ch : natural)
    return std_logic_vector is
  begin
    return std_logic_vector(to_unsigned(
      ((img*7919 + tap*1013 + ch*37 + 11) mod 65536), 16));
  end function;

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

  -- What `r_w` must hold for (img, seg, grp): the whole KCONV x CONV_LANES
  -- block, assembled from the image by the bit-order rule in the header.
  function want(img : natural; seg : integer; grp : natural)
    return std_logic_vector is
    variable v : std_logic_vector(KCONV*GW-1 downto 0);
  begin
    for k in 0 to KCONV-1 loop
      for ln in 0 to CONV_LANES-1 loop
        v(k*GW + (ln+1)*16 - 1 downto k*GW + ln*16)
          := wval(img, k, chan_of(seg, grp, ln));
      end loop;
    end loop;
    return v;
  end function;
begin
  clk <= not clk after 5 ns;

  dut : entity work.gdn_conv_w_mem
    -- "auto" here and "block" on the card.  `ram_style` is a SYNTHESIS
    -- attribute; GHDL ignores it, so this bench runs identically either way.
    generic map(KCONV => KCONV, CONV_LANES => CONV_LANES,
                KEY_CH => KEY_CH, VAL_CH => VAL_CH, STYLE => "auto")
    port map(clk => clk,
             r_seg => r_seg, r_grp => r_grp, r_w => r_w,
             m_w_en => m_w_en, m_w_addr => m_w_addr, m_w_data => m_w_data);

  stim : process is
    variable n_chk, n_bad : natural := 0;
    variable n_grp  : natural := 0;   -- (img, seg, grp) blocks checked
    variable n_edge : natural := 0;   -- proofs the read is NOT combinational
    variable n_noen : natural := 0;   -- proofs a write needs its enable

    procedure tick(n : natural := 1) is
    begin
      for i in 1 to n loop wait until rising_edge(clk); end loop;
    end procedure;

    procedure chk(cond : boolean; msg : string) is
    begin
      n_chk := n_chk + 1;
      if not cond then
        n_bad := n_bad + 1;
        report "tb_gdn_conv_w_mem: " & msg severity error;
      end if;
    end procedure;

    -- Drive an address at a FALLING edge, so the pre-edge check below is
    -- unambiguous, then cross ONE rising edge and settle a real 1 ns.
    procedure drive_addr(seg : integer; grp : natural) is
    begin
      wait until falling_edge(clk);
      r_seg <= seg; r_grp <= grp;
      wait for 1 ns;
    end procedure;

    procedure mover_write(a : natural; d : std_logic_vector) is
    begin
      m_w_en <= '1'; m_w_addr <= a; m_w_data <= d;
      tick;
      m_w_en <= '0';
    end procedure;

    procedure load_image(img : natural) is
    begin
      for a in 0 to WORDS-1 loop
        mover_write(a, wval(img, a / QKVN, a mod QKVN));
      end loop;
      -- ONE MORE EDGE.  The read register samples the array on the same
      -- edge the last word is written, and a BRAM reads the OLD word then
      -- (read-before-write).  MEASURED: without this tick the pre-edge
      -- check of the first block saw the last word of the previous image.
      tick;
    end procedure;

    variable before : std_logic_vector(KCONV*GW-1 downto 0);
    variable pseg : integer := 0;
    variable pgrp : natural := 0;
  begin
    tick(2);

    -- ---- before any load: zeros, which is what an unloaded layer is ------
    for seg in 0 to 2 loop
      for grp in 0 to grps_in(seg)-1 loop
        drive_addr(seg, grp);
        wait until rising_edge(clk); wait for 1 ns;
        chk(unsigned(r_w) = 0, "unloaded seg " & integer'image(seg)
            & " grp " & integer'image(grp) & " is not zero: "
            & to_hstring(r_w));
      end loop;
    end loop;
    -- The address is left at (2, last) through every load below, so the
    -- read register holds THAT block of the image just loaded when the
    -- pass begins.
    pseg := 2; pgrp := grps_in(2)-1;

    for img in 0 to NIMG-1 loop
      load_image(img);

      -- ---- every (seg, grp): the block is the image's, and it arrives on
      -- ---- the edge and not before ------------------------------------
      for seg in 0 to 2 loop
        for grp in 0 to grps_in(seg)-1 loop
          drive_addr(seg, grp);
          -- BEFORE the edge: still the PREVIOUS address's block.  On the
          -- very first block of an image the previous address is the last
          -- one of the previous pass, which also holds this image's value
          -- (the load has finished), so the check is still exact.
          before := r_w;
          chk(before = want(img, pseg, pgrp),
              "img " & integer'image(img) & " seg " & integer'image(seg)
              & " grp " & integer'image(grp)
              & ": r_w changed BEFORE the rising edge (combinational read?)"
              & " got " & to_hstring(before));
          n_edge := n_edge + 1;
          wait until rising_edge(clk); wait for 1 ns;
          chk(r_w = want(img, seg, grp),
              "img " & integer'image(img) & " seg " & integer'image(seg)
              & " grp " & integer'image(grp) & ": got " & to_hstring(r_w)
              & " want " & to_hstring(want(img, seg, grp)));
          n_grp := n_grp + 1;
          pseg := seg; pgrp := grp;
        end loop;
      end loop;

      -- ---- a write WITHOUT its enable changes nothing --------------------
      -- Drive the last word's address with a foreign value and no enable,
      -- then read the group that holds it.
      m_w_addr <= WORDS-1; m_w_data <= x"BEEF"; m_w_en <= '0';
      tick;
      drive_addr(2, grps_in(2)-1);
      wait until rising_edge(clk); wait for 1 ns;
      chk(r_w = want(img, 2, grps_in(2)-1),
          "img " & integer'image(img)
          & ": a write with m_w_en low altered the memory: "
          & to_hstring(r_w));
      n_noen := n_noen + 1;
      pseg := 2; pgrp := grps_in(2)-1;
    end loop;

    tick(2);
    report "tb_gdn_conv_w_mem: checks=" & integer'image(n_chk)
         & " bad=" & integer'image(n_bad)
         & " images=" & integer'image(NIMG)
         & " blocks=" & integer'image(n_grp)
         & " edge proofs=" & integer'image(n_edge)
         & " no-enable proofs=" & integer'image(n_noen) severity note;

    assert n_grp > 0
      report "tb_gdn_conv_w_mem: FAIL, no block was ever checked."
      severity failure;
    assert n_edge > 0
      report "tb_gdn_conv_w_mem: FAIL, the read's edge was never proved."
      severity failure;
    assert NIMG >= 2
      report "tb_gdn_conv_w_mem: FAIL, NIMG < 2 never checks replacement."
      severity failure;

    if n_bad = 0 then
      report "tb_gdn_conv_w_mem RESULT: PASS -- " & integer'image(n_chk)
           & " checks, " & integer'image(n_grp) & " (image, seg, grp) blocks "
           & "across " & integer'image(NIMG) & " images, each replacing the "
           & "last; every tap and lane in image order, on the edge and not "
           & "before it." severity note;
    else
      report "tb_gdn_conv_w_mem RESULT: FAIL -- " & integer'image(n_bad)
           & " of " & integer'image(n_chk) severity error;
    end if;
    finish;
  end process;
end architecture;
