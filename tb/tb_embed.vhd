-- tb/tb_embed.vhd
-- Testbench for rtl/embed.vhd.
-- Reads the prompt token ids from mem/golden/prompt_tokens.txt (5 ids) and
-- the corresponding golden BFP-encoded embedding rows from
-- mem/golden/fx_embed.txt (5 consecutive BFP sections, same order). Drives
-- the DUT with each token id in turn and compares x_mant/x_exp to the
-- golden, in the reconstructed integer domain (aligned to the finer
-- exponent), within +/-2 LSB.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.textio.all;
use work.golden_pkg.all;

entity tb_embed is end;

architecture sim of tb_embed is
  constant DIM  : integer := 64;
  constant NTOK : integer := 5;  -- prompt: "Once upon a time" -> [1,403,407,261,378]

  signal clk    : std_logic := '0';
  signal token  : integer   := 0;
  signal done   : std_logic;
  signal x_mant : std_logic_vector(DIM*16-1 downto 0);
  signal x_exp  : integer;
begin
  clk <= not clk after 5 ns;

  uut: entity work.embed
    generic map(
      DIM        => DIM,
      VOCAB      => 512,
      WEIGHT_DIR => "../mem/weights/"
    )
    port map(
      clk    => clk,
      token  => token,
      done   => done,
      x_mant => x_mant,
      x_exp  => x_exp
    );

  process
    file f_tok : text;
    file f_emb : text;

    variable tok_ids : integer_vector(0 to NTOK-1);

    variable n_g    : integer;
    variable gold_e : integer;
    variable gold_d : integer_vector(0 to DIM-1);

    variable dut_e   : integer;
    variable e_max   : integer;
    variable dut_m   : integer;
    variable gold_m  : integer;
    variable dut_sc  : integer;
    variable gold_sc : integer;
    variable dev     : integer;
    variable max_dev : integer := 0;
  begin
    -- ---- read prompt token ids ----
    file_open(f_tok, "../mem/golden/prompt_tokens.txt", read_mode);
    tok_ids := read_int_lines(f_tok, NTOK);
    file_close(f_tok);

    file_open(f_emb, "../mem/golden/fx_embed.txt", read_mode);

    for i in 0 to NTOK-1 loop
      -- ---- drive token, wait one clock for the registered BFP output ----
      token <= tok_ids(i);
      wait until rising_edge(clk);
      wait for 1 ns;  -- delta settle

      assert done = '1'
        report "token " & integer'image(i) & ": done not asserted" severity failure;

      -- ---- read golden BFP block i ----
      read_bfp_block(f_emb, n_g, gold_e, gold_d);
      assert n_g = DIM
        report "fx_embed.txt block " & integer'image(i) &
               ": expected n=" & integer'image(DIM) &
               " got " & integer'image(n_g) severity failure;

      -- ---- compare, aligned to the finer (larger) exponent ----
      dut_e := x_exp;
      if dut_e > gold_e then e_max := dut_e; else e_max := gold_e; end if;

      for j in 0 to DIM-1 loop
        dut_m   := to_integer(signed(x_mant((j+1)*16-1 downto j*16)));
        gold_m  := gold_d(j);
        dut_sc  := dut_m  * (2 ** (e_max - dut_e));
        gold_sc := gold_m * (2 ** (e_max - gold_e));
        if dut_sc >= gold_sc then dev := dut_sc - gold_sc;
        else                       dev := gold_sc - dut_sc; end if;
        if dev > max_dev then max_dev := dev; end if;
        assert dev <= 2
          report "token " & integer'image(tok_ids(i)) &
                 " element " & integer'image(j) &
                 " dut=" & integer'image(dut_sc) &
                 " golden=" & integer'image(gold_sc) &
                 " dev=" & integer'image(dev)
          severity failure;
      end loop;
    end loop;

    file_close(f_emb);

    report "PASS:embed  max_dev=" & integer'image(max_dev) severity note;
    std.env.finish;
  end process;
end architecture;
