-- tb/tb_weights_pkg.vhd
-- GHDL testbench for rtl/weights_pkg.vhd (unified weight ROM constant package).
-- Pure-data check: asserts scattered constants equal the bit-exact values in the
-- mem/weights/*.mem source files (values hardcoded here, extracted at generation
-- time). Spot-checks WQ layer-0, W1 layer-3, and EMBED across their address maps,
-- plus a WQ_MULT sample. Prints "PASS:weights_pkg" on success.
library ieee; use ieee.std_logic_1164.all; use ieee.numeric_std.all;
use std.env.all;
use work.weights_pkg.all;

entity tb_weights_pkg is end;

architecture sim of tb_weights_pkg is
begin
  process
    variable errors : integer := 0;

    procedure check(got : integer; exp : integer; tag : string) is
    begin
      if got /= exp then
        errors := errors + 1;
        report "FAIL:weights_pkg " & tag
             & " got " & integer'image(got)
             & " expect " & integer'image(exp) severity error;
      end if;
    end procedure;
  begin
    -- structural sanity
    check(WQ'length, N_LAYERS*WQ_STRIDE, "WQ len");
    check(WQ_MULT'length, N_LAYERS*WQ_ROWS, "WQ_MULT len");
    check(W1'length, N_LAYERS*W1_STRIDE, "W1 len");
    check(EMBED'length, VOCAB*DIM, "EMBED len");
    check(CLASSIFIER'length, VOCAB*DIM, "CLASSIFIER len");
    check(FINAL_RMS_W'length, DIM, "FINAL_RMS_W len");

    -- WQ layer-0 : idx = i*64 + j (row-major)
    check(WQ(0*64+0), 4739, "WQ(0,0)");
    check(WQ(0*64+63), -10451, "WQ(0,63)");
    check(WQ(1*64+0), 13272, "WQ(1,0)");
    check(WQ(7*64+7), 14432, "WQ(7,7)");
    check(WQ(13*64+40), 3673, "WQ(13,40)");
    check(WQ(31*64+31), -3112, "WQ(31,31)");
    check(WQ(32*64+0), -1693, "WQ(32,0)");
    check(WQ(40*64+17), 5651, "WQ(40,17)");
    check(WQ(50*64+50), -1224, "WQ(50,50)");
    check(WQ(63*64+63), 7277, "WQ(63,63)");
    check(WQ(5*64+19), 8626, "WQ(5,19)");
    check(WQ(22*64+3), -767, "WQ(22,3)");
    check(WQ(44*64+44), 6172, "WQ(44,44)");
    check(WQ(60*64+1), 5078, "WQ(60,1)");
    check(WQ(11*64+55), -6249, "WQ(11,55)");
    check(WQ(2*64+33), 12273, "WQ(2,33)");
    check(WQ(37*64+9), 13191, "WQ(37,9)");
    check(WQ(28*64+62), 18550, "WQ(28,62)");
    check(WQ(19*64+19), -5420, "WQ(19,19)");
    check(WQ(63*64+0), 15749, "WQ(63,0)");
    check(WQ_MULT(0), 20115, "WQ_MULT(0)");

    -- W1 layer-3 : flat offset 3*W1_STRIDE + r*64 + c
    check(W1(3*W1_STRIDE + 0*64 + 0), 2109, "W1L3(0,0)");
    check(W1(3*W1_STRIDE + 171*64 + 63), 4289, "W1L3(171,63)");
    check(W1(3*W1_STRIDE + 86*64 + 32), 6867, "W1L3(86,32)");
    check(W1(3*W1_STRIDE + 100*64 + 10), -23914, "W1L3(100,10)");
    check(W1(3*W1_STRIDE + 50*64 + 50), 26288, "W1L3(50,50)");
    check(W1(3*W1_STRIDE + 5*64 + 5), -8620, "W1L3(5,5)");
    check(W1(3*W1_STRIDE + 160*64 + 1), -14507, "W1L3(160,1)");

    -- EMBED : idx = token*64 + i ; CLASSIFIER is the same (tied)
    check(EMBED(0*64 + 0), -10965, "EMBED(0,0)");
    check(EMBED(511*64 + 63), -17374, "EMBED(511,63)");
    check(EMBED(100*64 + 32), -5484, "EMBED(100,32)");
    check(EMBED(256*64 + 10), -6718, "EMBED(256,10)");
    check(EMBED(7*64 + 7), 950, "EMBED(7,7)");
    check(EMBED(400*64 + 50), -5965, "EMBED(400,50)");
    check(CLASSIFIER(256*64 + 10), -6718, "CLASSIFIER(256,10)");

    if errors = 0 then
      report "PASS:weights_pkg" severity note;
    else
      report "FAIL:weights_pkg " & integer'image(errors) & " errors" severity failure;
    end if;
    finish;
  end process;
end;
