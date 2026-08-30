#!/usr/bin/env python3
"""ooc_nwrom_bounded.py -- TRACK NWROM, 2026-08-29.

Rewrite the generated `ooc_normadapt` harness so `NW_N` comes from a GENERIC
instead of from `nw_count`'s line-counting `while not endfile` loop.

WHY THIS EXISTS.  MEASURED 2026-08-29: at the real 9B shape the committed
loader does not elaborate in Vivado at all.

    ERROR: [Synth 8-403] loop limit (65536) exceeded [...ooc_normadapt_top.vhd:187]
    ERROR: [Synth 8-421] mismatched array sizes in rhs and lhs of assignment [...:199]

Line 187 is `while not endfile(fh) loop` inside `nw_count`.  The image format is
one 4-hex-digit int16 PER LINE, so at 65 norm ops x 4096 elements the count loop
runs 266,240 times against Vivado's default `maxLoopLimit` of 65,536.  The
second error is the consequence, not a second fault: `nw_count` having failed,
`NW_N` is wrong and the `hread` target no longer matches.

That failure is a fact about the LOADER.  It is not a fact about the HARDWARE,
which is a `NW_N`-way mux over `NW_N` x 65,536 bits of real constant and is the
thing the area question is about.  This probe removes the loader's counting loop
and changes nothing else, so the area it measures is the area the committed RTL
would have if its elaboration-time count were bounded.

It is a PROBE.  It is generated into a scratch tree and never written to `rtl/`.

usage: ooc_nwrom_bounded.py <in.vhd> <out.vhd> <entity>

NO HARDWARE.  Reads and writes text files.
"""

import sys

COUNT_OLD = """        if NORM_W_IMAGE = "" then return 1; end if;
        file_open(ok, fh, NORM_W_IMAGE, read_mode);
        assert ok = open_ok
          report "llama_top: cannot open the norm gain image "
               & NORM_W_IMAGE severity failure;
        while not endfile(fh) loop
          readline(fh, l);
          n := n + 1;
        end loop;
        file_close(fh);
        assert n > 0 and n mod NN = 0
          report "llama_top: the norm gain image " & NORM_W_IMAGE & " has "
               & integer'image(n) & " lines, which is not a positive multiple "
               & "of the norm length " & integer'image(NN) & "."
          severity failure;
        return n / NN;
"""

COUNT_NEW = """        -- NWROM PROBE.  The committed body counts the image's LINES, and at
        -- the 9B shape that loop runs NW_OPS*NN = 266,240 times against
        -- Vivado's default maxLoopLimit of 65,536, so it does not elaborate.
        -- Here the count is a generic and nothing else changes.
        n := 0;                       -- keep `n` and `l` used
        if NORM_W_IMAGE = "" then return 1; end if;
        return NW_OPS;
"""

GEN_OLD = """    NORM_W_IMAGE : string   := "";
"""

GEN_NEW = """    NORM_W_IMAGE : string   := "";
    NW_OPS       : positive := 1;
"""


def main() -> int:
    if len(sys.argv) != 4:
        sys.stderr.write(__doc__)
        return 2
    src, dst, ent = sys.argv[1:]
    t = open(src).read()
    for name, old in (("nw_count body", COUNT_OLD), ("NORM_W_IMAGE generic", GEN_OLD)):
        if t.count(old) != 1:
            sys.stderr.write("BOUNDED ABORT: %s anchor matched %d times\n"
                             % (name, t.count(old)))
            return 3
    t = t.replace(COUNT_OLD, COUNT_NEW).replace(GEN_OLD, GEN_NEW)
    t = t.replace("entity ooc_normadapt is", "entity %s is" % ent)
    t = t.replace("architecture rtl of ooc_normadapt is",
                  "architecture rtl of %s is" % ent)
    # unused-variable noise only; `l` is still declared and still read by the
    # loader proper, so nothing about the loaded table changes.
    open(dst, "w").write(t)
    sys.stderr.write("BOUNDED OK %s -> %s entity=%s\n" % (src, dst, ent))
    return 0


if __name__ == "__main__":
    sys.exit(main())
