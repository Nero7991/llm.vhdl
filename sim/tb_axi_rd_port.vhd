-- sim/tb_axi_rd_port.vhd -- axi_rd_port against a behavioural AXI4 slave.
--
-- The slave answers with a data word derived from the address, so an out-of-
-- order or dropped beat shows up as a specific wrong address rather than as
-- generic corruption.  It injects random AR and R stalls, because a read port
-- that only works against a zero-latency always-ready slave has not been
-- tested at all.
--
-- The last case is the one that matters most: 7.7 says the FIFO must be FLUSHED
-- on start, because sub-regions are padded to whole 4 KB bursts and the burst
-- carrying the final needed beat also delivers padding beats that stay resident
-- when the job ends.  The residue differs per port, so without a flush the next
-- job's stream is misaligned by a per-port-varying amount -- silently.  So the
-- test abandons a job part-consumed and checks the NEXT job starts at its own
-- first beat.

library ieee;
use ieee.std_logic_1164.all;
use ieee.numeric_std.all;

entity tb_axi_rd_port is
  generic(SEED : integer := 1; STALL : natural := 3;
          MAXOUT : positive := 2; DEPTH : positive := 64);
end entity;

architecture sim of tb_axi_rd_port is
  constant AXI_DW : positive := 128;
  constant ADDR_W : positive := 32;
  constant BYTES  : positive := AXI_DW / 8;

  signal clk, rst : std_logic := '0';
  signal start    : std_logic := '0';
  signal base     : std_logic_vector(ADDR_W-1 downto 0) := (others => '0');
  signal n_beats  : integer := 0;

  signal arvalid, arready, rvalid, rready, rlast : std_logic := '0';
  signal araddr : std_logic_vector(ADDR_W-1 downto 0);
  signal arlen  : std_logic_vector(7 downto 0);
  signal arsize : std_logic_vector(2 downto 0);
  signal arburst: std_logic_vector(1 downto 0);
  signal rdata  : std_logic_vector(AXI_DW-1 downto 0) := (others => '0');

  signal q_valid, q_ready : std_logic := '0';
  signal q_data : std_logic_vector(AXI_DW-1 downto 0);

  signal finished : boolean := false;
  signal nbad : integer := 0;
begin
  rst <= '1', '0' after 40 ns;

  clkgen : process
  begin
    while not finished loop
      clk <= '0'; wait for 5 ns; clk <= '1'; wait for 5 ns;
    end loop;
    wait;
  end process;

  dut : entity work.axi_rd_port
    generic map(AXI_DW => AXI_DW, ADDR_W => ADDR_W, DEPTH => DEPTH,
                MAXB => 16, MAXOUT => MAXOUT)
    port map(clk => clk, rst => rst, start => start, base => base,
             n_beats => n_beats,
             arvalid => arvalid, arready => arready, araddr => araddr,
             arlen => arlen, arsize => arsize, arburst => arburst,
             rvalid => rvalid, rready => rready, rdata => rdata, rlast => rlast,
             q_valid => q_valid, q_data => q_data, q_ready => q_ready);

  -- ------------------------------------------------------- behavioural slave
  slave : process
    variable lf   : unsigned(15 downto 0) := to_unsigned(SEED*7919 + 1, 16);
    variable a    : unsigned(ADDR_W-1 downto 0);
    variable n    : integer;
    procedure tick is
    begin
      wait until rising_edge(clk);
      lf := lf(14 downto 0) & (lf(15) xor lf(13) xor lf(12) xor lf(10));
    end procedure;
  begin
    arready <= '0'; rvalid <= '0'; rlast <= '0';
    wait until rst = '0';   -- else the first delta samples arvalid as 'U'
    loop
      -- accept an AR, after a random delay
      arready <= '0';
      while arvalid = '0' loop tick; end loop;
      if STALL /= 0 then
        while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
      end if;
      a := unsigned(araddr);
      n := to_integer(unsigned(arlen)) + 1;
      assert arburst = "01" report "burst type must be INCR" severity failure;
      assert to_integer(unsigned(arsize)) = 4
        report "arsize must match AXI_DW" severity failure;
      arready <= '1'; tick; arready <= '0';

      -- return n beats, data = the beat's own word address
      for i in 0 to n-1 loop
        if STALL /= 0 then
          rvalid <= '0';
          while (to_integer(lf) mod STALL) = 0 loop tick; end loop;
        end if;
        rdata <= std_logic_vector(resize(a / BYTES, AXI_DW));
        rvalid <= '1';
        if i = n-1 then rlast <= '1'; else rlast <= '0'; end if;
        loop
          tick;
          exit when rready = '1';
        end loop;
        a := a + BYTES;
      end loop;
      rvalid <= '0'; rlast <= '0';
    end loop;
  end process;

  -- ------------------------------------------------------------------ driver
  drv : process
    variable got, want : integer;
    variable nb : integer := 0;

    procedure run_job(constant bs : integer; constant nbe : integer;
                      constant consume : integer; constant nm : string) is
    begin
      base    <= std_logic_vector(to_unsigned(bs, ADDR_W));
      n_beats <= nbe;
      wait until rising_edge(clk);
      start <= '1'; wait until rising_edge(clk); start <= '0';
      for i in 0 to consume-1 loop
        q_ready <= '1';
        loop
          wait until rising_edge(clk);
          exit when q_valid = '1';
        end loop;
        got  := to_integer(unsigned(q_data));
        want := bs / BYTES + i;
        if got /= want then
          nb := nb + 1;
          if nb < 6 then
            report nm & ": beat " & integer'image(i) &
                   " got "  & integer'image(got) &
                   " want " & integer'image(want) severity error;
          end if;
        end if;
      end loop;
      q_ready <= '0';
      wait until rising_edge(clk);
    end procedure;
  begin
    q_ready <= '0';
    wait until rst = '0';
    wait until rising_edge(clk);

    run_job(16#1000#, 64,  64, "job1 full");
    run_job(16#3000#, 48,  48, "job2 short-of-burst");
    -- ABANDON a job part-consumed, then start another: without the flush of
    -- 7.7 the residue would be delivered as job4's first beats.
    run_job(16#5000#, 64,  20, "job3 abandoned");
    run_job(16#9000#, 32,  32, "job4 after abandon");

    nbad <= nb;
    wait until rising_edge(clk);
    report "axi_rd_port: " & integer'image(nbad) & " bad beats" severity note;
    assert nbad = 0 report "axi_rd_port DELIVERED THE WRONG BEATS"
      severity failure;
    finished <= true;
    wait;
  end process;
end architecture;
