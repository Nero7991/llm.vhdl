#!/usr/bin/env python3
"""TRACK LUTDIET: derive rmsnorm_rs_hotw from rmsnorm_rs.

WHY THIS VARIANT EXISTS.  The census says the dominant cost of the flat port is
NOT the read mux (which carries all the F7/F8) but the variable-index WRITE into
the flat output register.  That could be either (a) intrinsic to holding the
vector in flops, or (b) an artefact of how Vivado infers a slice assignment
whose base is a runtime variable.  If (b), a fix exists that costs NO memory and
CHANGES NO INTERFACE: write the register from a per-word generate with an
explicit constant index and an explicit comparator, which is a clock enable.
This variant is that experiment and nothing else -- the ports are byte-for-byte
the original's."""
import re, sys
src = open(sys.argv[1]).read()
n = {}
def need(old, new, name, count=1):
    global src
    c = src.count(old)
    if c != count: raise SystemExit("TRANSFORM MISS: %s found %d expected %d" % (name, c, count))
    src = src.replace(old, new); n[name] = c

need('entity rmsnorm_rs is', 'entity rmsnorm_rs_hotw is', 'entity')
need('architecture rtl of rmsnorm_rs is', 'architecture rtl of rmsnorm_rs_hotw is', 'arch')

need("""  signal o_reg : std_logic_vector(N*16-1 downto 0) := (others => '0');
begin
  o_mant <= o_reg;
""",
"""  signal o_reg : std_logic_vector(N*16-1 downto 0) := (others => '0');
  -- LUTDIET.  The write is registered and presented as {enable, word address,
  -- LANES data words}, exactly as it would be to a RAM, and then decoded by a
  -- per-word generate with a CONSTANT index.  Nothing else changes: the port
  -- list, the arithmetic, the pipeline depth and the values are the original's.
  signal o_we : std_logic := '0';
  signal o_wa : natural range 0 to NB-1 := 0;
  -- o_wd is ONE flat LANES*16 word group, not an array of LANES words, and
  -- that is load-bearing.  MEASURED in GHDL: with `o_reg(<expr in k>) <= ...`
  -- inside a for-loop in each generated process, the driver created is for the
  -- WHOLE o_reg rather than for the slice, so all NB processes drive every bit
  -- and the resolved output is 'X'.  A fully static slice target per generate
  -- gives each process a driver over its own bits and only its own bits.
  signal o_wd : std_logic_vector(LANES*16-1 downto 0) := (others => '0');
begin
  o_mant <= o_reg;

  gow : for wi in 0 to NB-1 generate
    process(clk) begin
      if rising_edge(clk) then
        if o_we = '1' and o_wa = wi then
          o_reg((wi+1)*LANES*16-1 downto wi*LANES*16) <= o_wd;
        end if;
      end if;
    end process;
  end generate;
""", 'oreg_decl')

need("""            if v3 = '1' then
              base := idx3 * LANES;
              for k in 0 to LANES-1 loop
                om := shift_right(p3_sum(k), shift_total);
                if    om > 32767  then
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(32767, 16));
                elsif om < -32768 then
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(to_signed(-32768, 16));
                else
                  o_reg((base+k+1)*16-1 downto (base+k)*16)
                    <= std_logic_vector(resize(om, 16));
                end if;
              end loop;
            end if;""",
"""            o_we <= v3;
            o_wa <= idx3 mod NB;
            if v3 = '1' then
              for k in 0 to LANES-1 loop
                om := shift_right(p3_sum(k), shift_total);
                if    om > 32767  then
                  o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(to_signed(32767, 16));
                elsif om < -32768 then
                  o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(to_signed(-32768, 16));
                else
                  o_wd((k+1)*16-1 downto k*16) <= std_logic_vector(resize(om, 16));
                end if;
              end loop;
            end if;""", 'emit')

need("""            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;""",
"""            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0'
               and o_we = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;""", 'done')

hdr = ("-- rtl-variant, TRACK LUTDIET 2026-08-29.  DERIVED MECHANICALLY from\n"
       "-- rtl/rmsnorm_rs.vhd by hw/fk33/results/lutdiet_2026-08-29/mkhotw.py.\n"
       "-- MEASUREMENT ARTEFACT.  Do not edit by hand; do not move into rtl/.\n")
open(sys.argv[2], "w").write(hdr + src)
print("TRANSFORM OK:", n)
