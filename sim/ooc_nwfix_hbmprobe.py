#!/usr/bin/env python3
"""ooc_nwfix_hbmprobe.py -- TRACK NWFIX, 2026-08-29.

Turn `sim/ooc_normadapt_extract.py`'s output into the probe that prices TRACK
NWROM's recommendation: **put the RMSNorm gain in HBM like every other weight**,
at which point the 65-entry elaboration-time table and its 65:1 select do not
exist and all that remains at this seam is the streaming write into the
65,536-bit register `rmsnorm_rs`'s flat `w_mant` port requires.

NWROM priced that write at `gvr.wsw` = 5,532 LUT / 61,440 FF from a census row
and called the whole-block figure an ESTIMATE of ~72,000 LUT.  This probe makes
it a MEASUREMENT of the adapter.  What it does NOT measure is stated in the
write-up and must be stated wherever the number is quoted: **there is no region
read path here** -- no address generation, no AXI read master, no burst logic,
no schedule deciding which gain to fetch.  The number this produces is a FLOOR
for the HBM route, not its price.

WHAT CHANGES, and nothing else:
  * the entity is renamed;
  * `nw_count`, `nw_load`, `NW_N` and `NW_TBL` are deleted;
  * `nidx` / `novf` / the `nsel` table read are replaced by a GW_W-bit shift
    register that streams the gain into `wsel`, element 0 first, which is the
    same element order the constant table held;
  * two ports carry that stream in.

EVERY substitution is anchored and every anchor is checked for EXACTLY ONE
match, including the entity rename.  TRACK NWROM's section 7.4 records the cost
of the alternative: a script that aborted loudly on its two checked anchors and
then did its entity rename with a bare unchecked `str.replace`, which matched
nothing, printed OK, and failed inside Vivado two runs later.

NO HARDWARE.  This script reads and writes text files and nothing else.

usage: ooc_nwfix_hbmprobe.py <in.vhd> <out.vhd> [ENTITY]
"""

import sys


def sub1(text: str, old: str, new: str, what: str) -> str:
    n = text.count(old)
    if n != 1:
        sys.stderr.write(
            f"ooc_nwfix_hbmprobe: anchor '{what}' matched {n} times, "
            f"expected exactly 1.  Refusing.\n")
        sys.exit(2)
    return text.replace(old, new)


def cut1(text: str, start: str, end: str, what: str, keep: str = "") -> str:
    """Delete from the line containing `start` through the line containing
    `end`, inclusive.  Both must occur exactly once."""
    for tag, s in (("start", start), ("end", end)):
        if text.count(s) != 1:
            sys.stderr.write(
                f"ooc_nwfix_hbmprobe: {what} {tag} anchor matched "
                f"{text.count(s)} times, expected exactly 1.  Refusing.\n")
            sys.exit(2)
    i = text.index(start)
    j = text.index(end, i) + len(end)
    if j <= i:
        sys.stderr.write(f"ooc_nwfix_hbmprobe: {what} end precedes start.\n")
        sys.exit(2)
    return text[:i] + keep + text[j:]


STREAM = """-- THE GAIN AS A STREAM, NOT AS A TABLE.  TRACK NWFIX probe.
      --
      -- `rmsnorm_rs`'s `w_mant` is one flat NN*MANT_W combinational port, so
      -- the SELECTED gain has to be resident in NN*MANT_W fabric flops
      -- whatever supplies it -- that part is not a choice and does not change
      -- between the ROM route and the HBM route.  What DOES change is
      -- everything upstream of the register: with the gain in HBM there is no
      -- 65-entry constant, no 65:1 select over a 65,536-bit word, and no
      -- elaboration-time image at all.
      --
      -- The write is a shift register and not a runtime-indexed slice.  TRACK
      -- LUTDIET and TRACK WRITEDEC both measured that a runtime slice write
      -- into a wide register infers a barrel shifter over the whole register
      -- rather than a write decoder; the shift register is correct here for
      -- the same reason it is correct in `xw`, namely that the beats arrive in
      -- order and nothing reads the vector until the last one has landed.
      --
      -- Element 0 arrives FIRST and ends up in the low word, which is the
      -- order the deleted constant table held and the order
      -- `sim/ooc_nwrom_gen_image.py` writes.
      gwr : process(clk) is
      begin
        if rising_edge(clk) then
          if i_gw_valid = '1' then
            wsel <= i_gw_data & wsel(NN*MANT_W-1 downto GW_W);
          end if;
        end if;
      end process;"""


def main() -> int:
    if len(sys.argv) < 3:
        sys.stderr.write(__doc__)
        return 2
    src, dst = sys.argv[1], sys.argv[2]
    ent = sys.argv[3] if len(sys.argv) > 3 else "ooc_nwfix_hbm"
    t = open(src).read()

    t = sub1(t, "entity ooc_normadapt is", f"entity {ent} is", "entity decl")
    t = sub1(t, "end entity;", "end entity;", "end entity")   # presence check
    t = sub1(t, "architecture rtl of ooc_normadapt is",
             f"architecture rtl of {ent} is", "architecture decl")

    # -- the generic and the two ports the stream needs ---------------------
    t = sub1(t,
             "    NORM_REAL    : boolean  := true\n  );",
             "    NORM_REAL    : boolean  := true;\n"
             "    -- The HBM beat width.  256 is the FK33 HBM pseudo-channel\n"
             "    -- data width; nothing here depends on the value beyond\n"
             "    -- NN*MANT_W being a whole number of beats.\n"
             "    GW_W         : positive := 256\n  );",
             "generic tail")
    t = sub1(t,
             "    i_el_rdata : in  signed(MANT_W-1 downto 0);",
             "    i_el_rdata : in  signed(MANT_W-1 downto 0);\n"
             "    i_gw_data  : in  std_logic_vector(GW_W-1 downto 0);\n"
             "    i_gw_valid : in  std_logic;",
             "port list")

    # -- delete the loader and the table ------------------------------------
    t = cut1(t,
             "      -- IT COUNTS IN GROUPS OF `NN`, NOT IN LINES",
             "      constant NW_TBL : nw_t := nw_load;",
             "loader",
             keep="      -- (the whole elaboration-time gain loader and its\n"
                  "      --  constant table are deleted by ooc_nwfix_hbmprobe.py)\n")

    # -- the index signals and the table-initialised register ---------------
    t = cut1(t,
             "      -- `nidx` is PINNED for the whole of the operation it names",
             "      signal wsel : std_logic_vector(NN*MANT_W-1 downto 0) "
             ":= NW_TBL(0);",
             "index signals",
             keep="      signal wsel : std_logic_vector(NN*MANT_W-1 downto 0)\n"
                  "        := (others => '0');\n")

    # -- the banner, which quotes NW_N --------------------------------------
    t = sub1(t,
             "                 & integer'image(NW_N) & \" norm ops from \" "
             "& NORM_W_IMAGE",
             "                 & \"streamed from a region\"",
             "banner")

    # -- the select process becomes the shift register ----------------------
    t = cut1(t,
             "      -- The norm-op counter.  Separate from `nproc` so that",
             "      end process;\n\n      nproc : process(clk) is",
             "nsel process",
             keep="      " + STREAM + "\n\n      nproc : process(clk) is")

    open(dst, "w").write(t)
    for banned in ("NW_TBL", "NW_N", "nidx", "novf", "nw_count", "nw_load"):
        if banned in t:
            sys.stderr.write(
                f"ooc_nwfix_hbmprobe: '{banned}' still present in the output.  "
                f"Refusing to claim the table was removed.\n")
            return 2
    print(f"HBMPROBE OK {src} -> {dst} entity={ent}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
