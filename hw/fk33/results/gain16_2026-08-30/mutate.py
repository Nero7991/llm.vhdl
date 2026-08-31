#!/usr/bin/env python3
"""mutate.py -- TRACK GAIN16, 2026-08-30.  Teeth for the ROM oracle.

Each mutant is an EXACT-STRING rewrite of one construct in the gain store, and
every one aborts if its anchor does not match exactly once.  A mutation that
silently matched nothing would produce the unmutated design under the mutant's
name, i.e. a PASS that reads as "the check has no teeth" when it really means
"the mutation never happened".

THE ROWS, and what each one is FOR:

  raw store (`head`, the shipping 16-bit ROM)
    T1 vecrev   pack each gain vector in reverse element order
    T2 vec0     drop `nidx` from the ROM address: every op reads vector 0
    T3 vecoff   pack vector k's data at vector k's slot from source k+1

  codebook (`cb`)
    E1 cbval    every codeword is one greater than the value it stands for
    E2 cbidx    every index is one greater than the codeword it should pick
    E3 cbdesc   build the codebook in DESCENDING value order.  This is a
                CONSISTENT permutation and is NOT a bug: it is a different but
                equally correct encoding of the same table.  It is here to
                measure what the oracle does NOT constrain, and it is expected
                NOT to bite.  Reported under its own name either way.
    E5a cbone1  corrupt the ONE codeword for 0x250, a value that occurs
                EXACTLY ONCE in all 266,240 elements.  The resolution floor:
                one wrong element in 266,240.
    E5b cbone802 corrupt the codeword for 0x1238, which occurs 802 times in
                norm_w_9b.hex and ZERO times in sim/llama_top_nw_b4_mean.hex.
                This is the ATTRIBUTION row: the pre-existing landmark
                `sim:tb_llama_top_normw` cannot reach it, because its image
                does not contain that value at all.

NO HARDWARE.

usage: mutate.py <in.vhd> <out.vhd> <mutant>
"""

import sys

M = {}

M["T1"] = ("""              r(k*NWORD + w) := NW_TBL(k)((w+1)*WW-1 downto w*WW);
""",
           """              r(k*NWORD + (NWORD-1-w)) := NW_TBL(k)((w+1)*WW-1 downto w*WW);
""")

M["T2"] = ("""            wrd   <= nwrom(nidx*NWORD + (wel / GW));
""",
           """            wrd   <= nwrom(0*NWORD + (wel / GW));
""")

M["T3"] = ("""              r(k*NWORD + w) := NW_TBL(k)((w+1)*WW-1 downto w*WW);
""",
           """              r(k*NWORD + w) := NW_TBL((k+1) mod NW_N)((w+1)*WW-1 downto w*WW);
""")

M["E1"] = ("""                r.t(r.n) := std_logic_vector(to_unsigned(a*256 + b, MANT_W));
""",
           """                r.t(r.n) := std_logic_vector(to_unsigned((a*256 + b + 1) mod 65536, MANT_W));
""")

M["E2"] = ("""              r(k*NWORD + w) := std_logic_vector(to_unsigned(
                CBB.m(to_integer(unsigned(
                  NW_TBL(k)((w+1)*MANT_W-1 downto w*MANT_W)))), IXW));
""",
           """              r(k*NWORD + w) := std_logic_vector(to_unsigned(
                (1 + CBB.m(to_integer(unsigned(
                  NW_TBL(k)((w+1)*MANT_W-1 downto w*MANT_W))))) mod NCB, IXW));
""")

M["E3"] = ("""          r.n := 0;
          for a in 0 to 255 loop
            for b in 0 to 255 loop
              if r.m(a*256 + b) = 0 then
""",
           """          r.n := 0;
          for a in 255 downto 0 loop
            for b in 255 downto 0 loop
              if r.m(a*256 + b) = 0 then
""")

_CBROM = """          for i in 0 to NCB-1 loop
            r(i) := CBB.t(i);
          end loop;
"""


def _cbone(v):
    return (_CBROM,
            """          for i in 0 to NCB-1 loop
            if CBB.t(i) = std_logic_vector(to_unsigned(%d, MANT_W)) then
              r(i) := (others => '0');
            else
              r(i) := CBB.t(i);
            end if;
          end loop;
""" % v)


M["E5a"] = _cbone(0x250)     # occurs exactly once in norm_w_9b.hex
M["E5b"] = _cbone(0x1238)    # occurs 802 times; absent from the b4_mean image


def main():
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    src, dst, name = sys.argv[1], sys.argv[2], sys.argv[3]
    if name not in M:
        sys.stderr.write("MUTATE ABORT: unknown mutant %r\n" % name)
        return 2
    a, b = M[name]
    t = open(src).read()
    n = t.count(a)
    if n != 1:
        sys.stderr.write("MUTATE ABORT: %s anchor matched %d times, expected 1\n"
                         % (name, n))
        return 2
    open(dst, "w").write(t.replace(a, b))
    sys.stderr.write("MUTATE OK %s -> %s\n" % (name, dst))
    return 0


if __name__ == "__main__":
    sys.exit(main())
