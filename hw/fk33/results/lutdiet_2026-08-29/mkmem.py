#!/usr/bin/env python3
"""TRACK LUTDIET: derive rmsnorm_rs_mem from rmsnorm_rs by a MINIMAL, scripted
transform, so the delta is auditable and nobody has to trust a hand-retyped
602-line file.  Every substitution below is asserted to have fired exactly the
expected number of times; a miss is a hard error, not a silent no-op."""
import re, sys

src = open(sys.argv[1]).read()
n_applied = {}

def sub(name, pat, rep, count):
    global src
    new, n = re.subn(pat, rep, src, flags=re.M)
    if n != count:
        raise SystemExit("TRANSFORM MISS: %s fired %d times, expected %d" % (name, n, count))
    src = new
    n_applied[name] = n

# ---- 1. entity / architecture name -----------------------------------------
sub("entity", r'^entity rmsnorm_rs is$', 'entity rmsnorm_rs_mem is', 1)
sub("endent", r'^end entity;$', 'end entity;', 1)
sub("arch",   r'^architecture rtl of rmsnorm_rs is$', 'architecture rtl of rmsnorm_rs_mem is', 1)

# ---- 2. ports: flat whole-vector -> banked memory ---------------------------
old_ports = """    x_mant : in  std_logic_vector(N*16-1 downto 0);
    x_exp  : in  integer;
    w_mant : in  std_logic_vector(N*16-1 downto 0);
    w_exp  : in  integer;
    done   : out std_logic;
    o_mant : out std_logic_vector(N*16-1 downto 0);
    o_exp  : out integer"""
new_ports = """    -- LUTDIET.  The ONLY change against rmsnorm_rs: the three flat
    -- whole-vector ports (3 x N*16 = 196,608 bits at N=4096) become word
    -- streams into and out of LANES-way banked block RAM held INSIDE the unit.
    -- Word index i lives in bank (i mod LANES) at offset (i / LANES), which is
    -- exactly the order the element passes walk it, so each pass reads one
    -- word per bank per cycle and the compute schedule is UNCHANGED.
    x_we    : in  std_logic;
    x_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    x_wdata : in  std_logic_vector(15 downto 0);
    x_exp   : in  integer;
    w_we    : in  std_logic;
    w_waddr : in  std_logic_vector(clog2(N)-1 downto 0);
    w_wdata : in  std_logic_vector(15 downto 0);
    w_exp   : in  integer;
    done    : out std_logic;
    o_raddr : in  std_logic_vector(clog2(N)-1 downto 0);
    o_rdata : out std_logic_vector(15 downto 0);
    o_exp   : out integer"""
if old_ports not in src: raise SystemExit("TRANSFORM MISS: port block")
src = src.replace(old_ports, new_ports); n_applied["ports"] = 1

# ---- 3. drop the fetch registers the RAM output register replaces ----------
old_regs = """  signal xf, wf  : s16a := (others => (others => '0'));
  signal vf      : std_logic := '0';
  signal va, vb  : std_logic := '0';
  signal xa      : s16a := (others => (others => '0'));"""
new_regs = """  -- LUTDIET.  xf/wf/xa were the registers that captured the output of the
  -- N-to-1 bus mux.  A block RAM's own output register IS that register, with
  -- the SAME one-cycle latency, so they are replaced one-for-one by x_q/w_q
  -- and no pipeline stage is added or removed.
  signal vf      : std_logic := '0';
  signal va, vb  : std_logic := '0';
  signal x_q, w_q : s16a := (others => (others => '0'));
  signal ram_ra  : std_logic_vector(clog2(NB)-1 downto 0) := (others => '0');
  signal o_we    : std_logic := '0';
  signal o_wa    : std_logic_vector(clog2(NB)-1 downto 0) := (others => '0');
  type   sl16a is array(0 to LANES-1) of std_logic_vector(15 downto 0);
  signal o_wd    : sl16a := (others => (others => '0'));
  signal x_bwe, w_bwe : std_logic_vector(LANES-1 downto 0) := (others => '0');
  signal x_bq, w_bq, o_bq : sl16a;
  signal o_rsel  : std_logic_vector(clog2(LANES)-1 downto 0) := (others => '0');"""
if old_regs not in src: raise SystemExit("TRANSFORM MISS: fetch register block")
src = src.replace(old_regs, new_regs); n_applied["fetchregs"] = 1

# ---- 4. drop o_reg and its continuous assign, add the RAM instances --------
old_oreg = """  signal o_reg : std_logic_vector(N*16-1 downto 0) := (others => '0');
begin
  o_mant <= o_reg;
"""
new_oreg = """begin
  -- LUTDIET.  The banked memories.  vec_mem is the repo's existing forced-block
  -- SDP RAM (rtl/vec_mem.vhd), added on 2026-07-27 for EXACTLY this reason on
  -- swiglu/bfp_pack: "Synth turned that into a 172-way 32-bit DEMUX plus two
  -- 172-way 32-bit MUXes -- several K LUTs on a LUT-bound design."
  gbank : for k in 0 to LANES-1 generate
    x_bwe(k) <= x_we when unsigned(x_waddr(clog2(LANES)-1 downto 0)) = k else '0';
    w_bwe(k) <= w_we when unsigned(w_waddr(clog2(LANES)-1 downto 0)) = k else '0';
    ux : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => x_bwe(k),
               waddr => x_waddr(clog2(N)-1 downto clog2(LANES)),
               raddr => ram_ra, din => x_wdata, dout => x_bq(k));
    uw : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => w_bwe(k),
               waddr => w_waddr(clog2(N)-1 downto clog2(LANES)),
               raddr => ram_ra, din => w_wdata, dout => w_bq(k));
    uo : entity work.vec_mem generic map(WORDS => NB, W => 16)
      port map(clk => clk, we => o_we, waddr => o_wa,
               raddr => o_raddr(clog2(N)-1 downto clog2(LANES)),
               din => o_wd(k), dout => o_bq(k));
    x_q(k) <= signed(x_bq(k));
    w_q(k) <= signed(w_bq(k));
  end generate;

  -- The read address the element passes present.  Combinational from idx, so
  -- the RAM output register lands the word in the SAME cycle xf/xa used to.
  ram_ra <= std_logic_vector(to_unsigned(idx, clog2(NB))) when idx < NB
            else (others => '0');

  -- The output word stream.  A LANES-to-1 mux (4:1 here), not an N-to-1 one.
  process(clk) begin
    if rising_edge(clk) then
      o_rsel <= o_raddr(clog2(LANES)-1 downto 0);
    end if;
  end process;
  o_rdata <= o_bq(to_integer(unsigned(o_rsel)));
"""
if old_oreg not in src: raise SystemExit("TRANSFORM MISS: o_reg block")
src = src.replace(old_oreg, new_oreg); n_applied["oreg"] = 1

# ---- 5. S_ACC: the bus-mux stage becomes address-only ----------------------
old_acc = """            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xa(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              va <= '1'; idx <= idx + 1;"""
new_acc = """            if idx < NB then
              -- LUTDIET: no mux here any more.  ram_ra is already idx.
              va <= '1'; idx <= idx + 1;"""
if old_acc not in src: raise SystemExit("TRANSFORM MISS: S_ACC")
src = src.replace(old_acc, new_acc); n_applied["s_acc"] = 1

sub("s_acc_sq", r'sq\(k\) <= resize\(xa\(k\) \* xa\(k\), 32\);',
    'sq(k) <= resize(x_q(k) * x_q(k), 32);', 1)

# ---- 6. S_RAW and S_EMIT: same, twice --------------------------------------
old_f = """            if idx < NB then
              base := idx * LANES;
              for k in 0 to LANES-1 loop
                xf(k) <= signed(x_mant((base+k+1)*16-1 downto (base+k)*16));
                wf(k) <= signed(w_mant((base+k+1)*16-1 downto (base+k)*16));
              end loop;
              vf <= '1'; idxf <= idx; idx <= idx + 1;"""
new_f = """            if idx < NB then
              -- LUTDIET: no mux here any more.  ram_ra is already idx.
              vf <= '1'; idxf <= idx; idx <= idx + 1;"""
c = src.count(old_f)
if c != 2: raise SystemExit("TRANSFORM MISS: fetch stage count %d" % c)
src = src.replace(old_f, new_f); n_applied["fetch_stage"] = 2

sub("mul_stage", r'p1_xinv\(k\) <= resize\(xf\(k\) \* inv32, 48\);\n(\s*)p1_wm\(k\)   <= resize\(wf\(k\), 17\);',
    r'p1_xinv(k) <= resize(x_q(k) * inv32, 48);\n\1p1_wm(k)   <= resize(w_q(k), 17);', 2)

# ---- 7. the output write: slice-of-a-flat-register -> bank write -----------
old_emit = """            if v3 = '1' then
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
            end if;"""
new_emit = """            -- LUTDIET.  Was a slice of a flat N*16 register selected by a
            -- variable base, i.e. an N/LANES-way DEMUX plus N*16 flops.  Now a
            -- write to bank k at offset idx3, which is one address, no demux.
            -- Same cycle, same value, same saturation.
            o_we <= v3;
            o_wa <= std_logic_vector(to_unsigned(idx3, clog2(NB)));
            if v3 = '1' then
              for k in 0 to LANES-1 loop
                om := shift_right(p3_sum(k), shift_total);
                if    om > 32767  then
                  o_wd(k) <= std_logic_vector(to_signed(32767, 16));
                elsif om < -32768 then
                  o_wd(k) <= std_logic_vector(to_signed(-32768, 16));
                else
                  o_wd(k) <= std_logic_vector(resize(om, 16));
                end if;
              end loop;
            end if;"""
if old_emit not in src: raise SystemExit("TRANSFORM MISS: S_EMIT write")
src = src.replace(old_emit, new_emit); n_applied["emit_write"] = 1

# The write now lands one cycle after v3, because o_wd/o_we/o_wa are registers
# feeding the RAM's own write port.  done must wait for it, or the last four
# words are not committed when the consumer starts reading.
old_done = """            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;"""
new_done = """            -- LUTDIET: + o_we.  The bank write is one cycle behind v3 (o_wd
            -- and o_we are registers feeding the RAM write port), so `done`
            -- must not fire until that last write has been taken.
            if idx = NB and vf = '0' and v1 = '0' and v2 = '0' and v3 = '0'
               and o_we = '0' then
              done  <= '1';
              state <= S_IDLE;
            end if;"""
if old_done not in src: raise SystemExit("TRANSFORM MISS: done condition")
src = src.replace(old_done, new_done); n_applied["done"] = 1

# ---- 8. the LANES power-of-two assertion the banking needs ------------------
sub("assert", r"(  assert 2\*\*LOG2N = N)",
    "  assert 2**clog2(LANES) = LANES\n"
    "    report \"rmsnorm_rs_mem: LANES must be a power of two (the bank index \"\n"
    "         & \"is the low bits of the word index)\" severity failure;\n\\1", 1)

hdr = ("-- rtl-variant, TRACK LUTDIET 2026-08-29.  DERIVED MECHANICALLY from\n"
       "-- rtl/rmsnorm_rs.vhd by hw/fk33/results/lutdiet_2026-08-29/mkmem.py.\n"
       "-- DO NOT EDIT BY HAND and DO NOT MOVE INTO rtl/ -- this is a MEASUREMENT\n"
       "-- ARTEFACT for the LUT-versus-BRAM trade, not a shipping unit.  It has\n"
       "-- been synthesised and checked bit-exact against the original in GHDL;\n"
       "-- it has NOT been through the project's gate.\n")
src = hdr + src
open(sys.argv[2], "w").write(src)
print("TRANSFORM OK:", n_applied)
