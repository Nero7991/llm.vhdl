#!/usr/bin/env python3
"""ooc_nwrom_memvariant.py -- TRACK NWROM, 2026-08-29.

Rewrite the generated `ooc_normadapt` harness so the norm-gain table is held in
an inferred MEMORY and streamed one element per cycle into the 65,536-bit
`wsel` register, instead of being an `NW_N`-way combinational mux of 65,536-bit
words.

THIS IS A PROBE, NOT A LANDING.  It answers one question -- what does the gain
store cost if it is a memory rather than logic -- and it deliberately does not
answer the scheduling question that a real landing would have to: the load here
free-runs, so it is AREA-accurate and says nothing about when the gain is
coherent.  A landed version would have to gate the load on the operation
boundary and prove the whole vector is resident before `rmsnorm_rs` reads it.
It is generated into a scratch tree and never written to `rtl/`.

Why the interface is not the lever here: `rmsnorm_rs`'s `w_mant` is a flat
NN*16 combinational port, so the SELECTED gain must be resident in fabric
registers no matter where the table lives.  Only the TABLE can move to memory.
Narrowing `w_mant` itself is TRACK READCONV's file and not this track's.

usage: ooc_nwrom_memvariant.py <in.vhd> <out.vhd> <entity> <block|ultra|auto>

NO HARDWARE.  Reads and writes text files.
"""

import sys

DECL_OLD = """      signal wsel : std_logic_vector(NN*MANT_W-1 downto 0) := NW_TBL(0);
"""

DECL_NEW = """      -- ==== NWROM PROBE: the gain table as a MEMORY ====================
      -- One flat word-addressed table of NW_N*NN 16-bit elements, read one
      -- element per cycle and written into `wsw`, whose flat view is `wsel`.
      -- The write target is a WHOLE WORD, which is TRACK NORMADAPT's form and
      -- not the runtime-slice form it removed.
      type nwrom_t is array (0 to NW_N*NN-1)
        of std_logic_vector(MANT_W-1 downto 0);
      function nwrom_flat return nwrom_t is
        variable r : nwrom_t;
      begin
        for kk in 0 to NW_N-1 loop
          for ii in 0 to NN-1 loop
            r(kk*NN+ii) := NW_TBL(kk)((ii+1)*MANT_W-1 downto ii*MANT_W);
          end loop;
        end loop;
        return r;
      end function;
      signal nwrom : nwrom_t := nwrom_flat;
      attribute rom_style : string;
      attribute rom_style of nwrom : signal is "@STYLE@";
      type wsw_t is array (0 to NN-1) of std_logic_vector(MANT_W-1 downto 0);
      signal wsw    : wsw_t := (others => (others => '0'));
      signal wptr   : natural range 0 to NN-1 := 0;
      signal wptr_d : natural range 0 to NN-1 := 0;
      signal wrd    : std_logic_vector(MANT_W-1 downto 0) := (others => '0');
      signal wsel   : std_logic_vector(NN*MANT_W-1 downto 0);
"""

BODY_ANCHOR = """      gxflat : for i in 0 to NN-1 generate
        xv((i+1)*MANT_W-1 downto i*MANT_W) <= xw(i);
      end generate;
"""

BODY_NEW = BODY_ANCHOR + """
      -- NWROM PROBE.  The flat view of the staged gain, one driver per bit.
      gwflat : for i in 0 to NN-1 generate
        wsel((i+1)*MANT_W-1 downto i*MANT_W) <= wsw(i);
      end generate;

      -- NWROM PROBE.  Free-running load: address on cycle c, datum on c+1,
      -- written on c+1 under the registered address.  AREA probe only.
      wload : process(clk) is
      begin
        if rising_edge(clk) then
          wrd    <= nwrom(nidx*NN + wptr);
          wptr_d <= wptr;
          if wptr = NN-1 then wptr <= 0; else wptr <= wptr + 1; end if;
          wsw(wptr_d) <= wrd;
        end if;
      end process;
"""

SEL_OLD = """          wsel <= NW_TBL(nidx);
"""

SEL_NEW = """          -- NWROM PROBE: the mux is gone; `wsel` is driven from `wsw`.
"""


def main() -> int:
    if len(sys.argv) != 5:
        sys.stderr.write(__doc__)
        return 2
    src, dst, ent, style = sys.argv[1:]
    t = open(src).read()
    for name, old in (("wsel decl", DECL_OLD), ("gxflat", BODY_ANCHOR),
                      ("wsel assign", SEL_OLD)):
        if t.count(old) != 1:
            sys.stderr.write("MEMVARIANT ABORT: %s anchor matched %d times\n"
                             % (name, t.count(old)))
            return 3
    t = t.replace(DECL_OLD, DECL_NEW.replace("@STYLE@", style))
    t = t.replace(BODY_ANCHOR, BODY_NEW)
    t = t.replace(SEL_OLD, SEL_NEW)
    t = t.replace("entity ooc_normadapt is", "entity %s is" % ent)
    t = t.replace("architecture rtl of ooc_normadapt is",
                  "architecture rtl of %s is" % ent)
    open(dst, "w").write(t)
    sys.stderr.write("MEMVARIANT OK %s -> %s entity=%s rom_style=%s\n"
                     % (src, dst, ent, style))
    return 0


if __name__ == "__main__":
    sys.exit(main())
