#!/usr/bin/env python3
"""mkprobe.py -- TRACK GAIN16, 2026-08-30.  SCRATCH PROBE HARNESS.

Add four OBSERVATION PORTS to a `sim/ooc_normadapt_extract.py` output so a
testbench can watch the gain word stream the ROM actually produces:

    o_p_we   nw_we    the bank write enable
    o_p_wa   nw_wa    the element index being written, zero-extended to 16
    o_p_wd   nw_wd    THE GAIN WORD, which is what the oracle compares
    o_p_ni   nidx     which of the NW_N gain vectors is loading

WHY PORTS AND NOT AN EXTERNAL NAME.  MEASURED 2026-08-30: GHDL 1.0.0 mcode
ANALYSES a VHDL-2008 external name (`<< signal dut.gvr.nw_wd : ... >>`) without
complaint and then dies at elaboration with

    translate_name: cannot handle IIR_KIND_EXTERNAL_SIGNAL_NAME
    ******************** GHDL Bug occurred ***************************

so hierarchical observation is not available on this simulator at all.  Do not
retry it.  (And note the rc for that run, taken off a pipeline, was 0 -- the
same trap TRACK GWTWO hit, hit again.)

WHY THIS IS HONEST.  The ports are TAPS.  They add four concurrent assignments
and change nothing the ROM does, so the values observed are the values the
elaborated ROM produced.  This file is deliberately NOT in rtl/ and its output
is deliberately NOT synthesised: it exists so a simulation oracle can see the
real elaborated table, and for nothing else.

NO HARDWARE.

usage: mkprobe.py <ooc_normadapt_top.vhd> <out.vhd>
"""

import sys

A_PORTS = """    obs_norm_n   : out unsigned(15 downto 0)
  );
end entity;
"""

N_PORTS = """    obs_norm_n   : out unsigned(15 downto 0);
    -- TRACK GAIN16 observation taps, added by mkprobe.py.
    o_p_we       : out std_logic;
    o_p_wa       : out std_logic_vector(15 downto 0);
    o_p_wd       : out std_logic_vector(15 downto 0);
    o_p_ni       : out std_logic_vector(15 downto 0)
  );
end entity;
"""

A_END = """    end generate;
-- ==== END VERBATIM llama_top gvr BLOCK ====
"""

N_END = """      -- TRACK GAIN16 observation taps, added by mkprobe.py.
      o_p_we <= nw_we;
      o_p_wa <= std_logic_vector(resize(unsigned(nw_wa), 16));
      o_p_wd <= nw_wd;
      o_p_ni <= std_logic_vector(to_unsigned(nidx, 16));
    end generate;
-- ==== END VERBATIM llama_top gvr BLOCK ====
"""


def once(t, a, n, name):
    c = t.count(a)
    if c != 1:
        sys.stderr.write("MKPROBE ABORT: anchor %s matched %d times\n" % (name, c))
        sys.exit(2)
    return t.replace(a, n)


def main():
    if len(sys.argv) != 3:
        sys.stderr.write(__doc__)
        return 2
    t = open(sys.argv[1]).read()
    t = once(t, A_PORTS, N_PORTS, "PORTS")
    t = once(t, A_END, N_END, "END")
    open(sys.argv[2], "w").write(t)
    sys.stderr.write("MKPROBE OK -> %s\n" % sys.argv[2])
    return 0


if __name__ == "__main__":
    sys.exit(main())
