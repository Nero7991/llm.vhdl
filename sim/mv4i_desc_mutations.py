#!/usr/bin/env python3
"""The mutation table for rtl/matvec_int4_desc_axi.vhd, applied one at a time
by sim/mutate_mv4i_desc.sh.

WHAT IS BEING MEASURED.  matvec_int4_desc_axi is subsystem A's GATEKEEPER: it
is the only thing between a descriptor in HBM and `start` reaching the array.
The failure that matters is not "it refused something legal" -- that is loud,
a driver polling for done hangs and someone looks -- but "it ACCEPTED something
it should have refused", which is silent and produces a wrong number or a read
of the wrong memory.  So the table is weighted toward mutations that WEAKEN a
check, and each such row is marked `weaken` in its note.

BRANCH TAGS.  A mutation is only observable through a case that runs the line.
Every row carries the branch that elaborates and reaches it:

  IMG   reached by sim/tb_mv4i_desc_image.vhd at the FK33 geometry, which is
        the harness's only judge.  It drives S_IDLE -> S_FETCH -> S_R ->
        S_CHECK -> S_SHAPE -> S_SHAPE_C -> S_CB -> S_START and stops there,
        because the 27 weight/scale slaves never answer.
  RUN   S_WAIT / S_DONE / the result buffer / the Y_IDX divider.  ELABORATED
        but NEVER REACHED by this harness: no job in it ever completes.  Rows
        tagged RUN are expected to survive HERE and that survival measures the
        harness, not the design.  sim/tb_matvec_fk33_desc.vhd is the bench that
        reaches them.
  GEN   guarded by a generic this harness does not set (USE_XEXP_PORT,
        DUAL_CLK).  NOT ELABORATED in the configuration under test.

An untagged table would read these three as one number and report a kill rate
that is a mixture of the design's teeth and the harness's reach.
"""
import sys

# (name, branch, note, old, new)
MUTATIONS = [

    # ------------------------------------------------ the pointer, in S_IDLE
    ("P1", "IMG", "weaken: the DESC_PTR range check removed entirely",
     "              if not fits_addr(dptr) then",
     "              if false then"),

    ("P2", "IMG", "weaken: the DESC_PTR alignment check removed entirely",
     "              elsif unsigned(dptr(clog2(DESC_ALIGN)-1 downto 0)) /= 0 then",
     "              elsif false then"),

    ("P3", "IMG", "weaken: DESC_ALIGN halved, so a half-aligned pointer passes",
     "  constant DESC_ALIGN : positive := DESC_MAXB * (AXI_DW / 8);",
     "  constant DESC_ALIGN : positive := DESC_MAXB * (AXI_DW / 16);"),

    ("P4", "IMG", "the DESC_PTR range check reads the LOW half, not the high",
     "              if not fits_addr(dptr) then",
     "              if not fits_addr(x\"00000000\" & dptr(31 downto 0)) then"),

    # ------------------------------------------------ the extension header
    ("X1", "IMG", "weaken: the extension MAGIC is not checked",
     "            if lo32(dw(EXT0)) /= MV4I_MAGIC then",
     "            if false then"),

    ("X2", "IMG", "the MAGIC is read from the WRONG half of its word",
     "            if lo32(dw(EXT0)) /= MV4I_MAGIC then",
     "            if hi32(dw(EXT0)) /= MV4I_MAGIC then"),

    ("X3", "IMG", "weaken: the extension VERSION is not checked",
     "            elsif to_integer(unsigned(dw(EXT0)(47 downto 32))) /= MV4I_DESC_VER then",
     "            elsif false then"),

    ("X4", "IMG", "the VERSION field is read one bit high",
     "            elsif to_integer(unsigned(dw(EXT0)(47 downto 32))) /= MV4I_DESC_VER then",
     "            elsif to_integer(unsigned(dw(EXT0)(48 downto 33))) /= MV4I_DESC_VER then"),

    ("X5", "IMG", "weaken: the extension's reserved ext_flags are not checked",
     "            elsif dw(EXT0)(63 downto 48) /= x\"0000\" then",
     "            elsif false then"),

    ("X6", "IMG", "the extension is decoded at word EXT0-1 throughout",
     "  v_wbeats <= lo32(dw(EXT0 + 1));",
     "  v_wbeats <= lo32(dw(EXT0));"),

    # ------------------------------------------------------ D's header words
    ("H1", "IMG", "weaken: NPORTS_W is not checked against the descriptor",
     "            elsif to_integer(unsigned(dw(3)(31 downto 16))) /= NPORTS_W\n"
     "               or to_integer(unsigned(dw(3)(47 downto 32))) /= NPORTS_S then",
     "            elsif to_integer(unsigned(dw(3)(47 downto 32))) /= NPORTS_S then"),

    ("H2", "IMG", "weaken: NPORTS_S is not checked against the descriptor",
     "            elsif to_integer(unsigned(dw(3)(31 downto 16))) /= NPORTS_W\n"
     "               or to_integer(unsigned(dw(3)(47 downto 32))) /= NPORTS_S then",
     "            elsif to_integer(unsigned(dw(3)(31 downto 16))) /= NPORTS_W then"),

    ("H3", "IMG", "weaken: the opcode is not checked, so any D job runs as an A job",
     "            elsif op /= OP_A_JOB then",
     "            elsif false then"),

    ("H4", "IMG", "weaken: word 3's reserved pad is not checked",
     "            elsif dw(3)(63 downto 56) /= x\"00\" then",
     "            elsif false then"),

    ("H5", "IMG", "weaken: word 7, D's reserved word, is not checked",
     "            elsif dw(7) /= x\"0000000000000000\" then",
     "            elsif false then"),

    ("H6", "IMG", "weaken: the extension's own pad words are not checked",
     "            elsif hi32(dw(EXT0 + 2)) /= x\"00000000\"\n"
     "               or dw(EXT0 + 3) /= x\"0000000000000000\" then",
     "            elsif false then"),

    ("H7", "IMG", "weaken: only the FIRST of the two extension pads is checked",
     "            elsif hi32(dw(EXT0 + 2)) /= x\"00000000\"\n"
     "               or dw(EXT0 + 3) /= x\"0000000000000000\" then",
     "            elsif hi32(dw(EXT0 + 2)) /= x\"00000000\" then"),

    ("H8", "IMG", "weaken: out_mode 3 is admitted (the bound moved by one)",
     "            elsif to_integer(unsigned(dw(3)(7 downto 0))) > 2 then",
     "            elsif to_integer(unsigned(dw(3)(7 downto 0))) > 3 then"),

    ("H9", "IMG", "the opcode is read from the wrong byte of word 0",
     "            op := to_integer(unsigned(dw(0)(7 downto 0)));",
     "            op := to_integer(unsigned(dw(0)(15 downto 8)));"),

    # ------------------------------------------------------------- the shape
    ("S1", "IMG", "weaken: n_rows = 0 is admitted",
     "            elsif unsigned(lo32(dw(1))) = 0\n"
     "               or unsigned(lo32(dw(1))) > MAXROWS_BFP",
     "            elsif unsigned(lo32(dw(1))) > MAXROWS_BFP"),

    ("S2", "IMG", "weaken: the n_rows ceiling is one too high",
     "               or unsigned(lo32(dw(1))) > MAXROWS_BFP",
     "               or unsigned(lo32(dw(1))) > MAXROWS_BFP + 1"),

    ("S3", "IMG", "tighten: the n_rows ceiling excludes MAXROWS_BFP itself",
     "               or unsigned(lo32(dw(1))) > MAXROWS_BFP",
     "               or unsigned(lo32(dw(1))) >= MAXROWS_BFP"),

    ("S4", "IMG", "weaken: n_cols = 0 is admitted",
     "               or unsigned(hi32(dw(1))) = 0\n"
     "               or unsigned(hi32(dw(1))) > MAXCOLS then",
     "               or unsigned(hi32(dw(1))) > MAXCOLS then"),

    ("S5", "IMG", "weaken: the n_cols ceiling is one too high",
     "               or unsigned(hi32(dw(1))) > MAXCOLS then",
     "               or unsigned(hi32(dw(1))) > MAXCOLS + 1 then"),

    ("S6", "IMG", "n_rows and n_cols are read from each other's half",
     "              sh_rows <= to_integer(unsigned(lo32(dw(1))));\n"
     "              sh_cols <= to_integer(unsigned(hi32(dw(1))));",
     "              sh_rows <= to_integer(unsigned(hi32(dw(1))));\n"
     "              sh_cols <= to_integer(unsigned(lo32(dw(1))));"),

    ("S7", "IMG", "weaken: a zero w_beats or s_beats is admitted",
     "            elsif unsigned(lo32(dw(EXT0 + 1))) = 0\n"
     "               or unsigned(hi32(dw(EXT0 + 1))) = 0 then",
     "            elsif false then"),

    # ---------------------------------------------------------- the bases
    ("B1", "IMG", "weaken: the base array's verdict is ignored entirely",
     "            elsif base_bad = '1' then",
     "            elsif false then"),

    ("B2", "IMG", "weaken: bases are not range checked",
     "      if bad = '0' and not fits_addr(dw(DESC_BASE0 + p)) then",
     "      if false then"),

    ("B3", "IMG", "weaken: bases are not alignment checked",
     "      if bad = '0' and not is_4k_aligned(dw(DESC_BASE0 + p)) then",
     "      if false then"),

    ("B4", "IMG", "weaken: base alignment is checked to 2 KB, not 4 KB",
     "    return v(11 downto 0) = x\"000\";",
     "    return v(10 downto 0) = \"00000000000\";"),

    ("B5", "IMG", "weaken: base alignment is checked to 256 bytes",
     "    return v(11 downto 0) = x\"000\";",
     "    return v(7 downto 0) = x\"00\";"),

    ("B6", "IMG", "weaken: a base bit exactly AT ADDR_W is admitted",
     "      if i >= ADDR_W and v(i) /= '0' then return false; end if;",
     "      if i > ADDR_W and v(i) /= '0' then return false; end if;"),

    ("B7", "IMG", "weaken: the LAST base is never checked",
     "    for p in 0 to NP_ALL-1 loop",
     "    for p in 0 to NP_ALL-2 loop"),

    ("B8", "IMG", "weaken: the FIRST base is never checked",
     "    for p in 0 to NP_ALL-1 loop",
     "    for p in 1 to NP_ALL-1 loop"),

    ("B9", "IMG", "weaken: only the WEIGHT bases are checked, not the scales",
     "    for p in 0 to NP_ALL-1 loop",
     "    for p in 0 to NPORTS_W-1 loop"),

    ("B10", "IMG", "ERR_INFO names the port, not the descriptor word",
     "        bad := '1'; code := EC_ADDR;\n"
     "        info := std_logic_vector(to_unsigned(DESC_BASE0 + p, 16));",
     "        bad := '1'; code := EC_ADDR;\n"
     "        info := std_logic_vector(to_unsigned(p, 16));"),

    ("B11", "IMG", "EC_ADDR and EC_ALIGN are swapped on the base array",
     "        bad := '1'; code := EC_ADDR;",
     "        bad := '1'; code := EC_ALIGN;"),

    ("B12", "IMG", "the base checker LAST match wins instead of the first",
     "      if bad = '0' and not fits_addr(dw(DESC_BASE0 + p)) then",
     "      if not fits_addr(dw(DESC_BASE0 + p)) then"),

    # ------------------------------------------------------ the shape gate
    ("G1", "IMG", "the tile accumulator steps by ROWS_IF + 1",
     "                sh_racc <= sh_racc + ROWS_IF;",
     "                sh_racc <= sh_racc + ROWS_IF + 1;"),

    ("G2", "IMG", "the block accumulator steps by BLK * 2",
     "                sh_cacc <= sh_cacc + BLK;",
     "                sh_cacc <= sh_cacc + BLK * 2;"),

    ("G3", "IMG", "the loop exits one step late on the ROW dimension",
     "            if sh_racc >= sh_rows and sh_cacc >= sh_cols then",
     "            if sh_racc > sh_rows and sh_cacc >= sh_cols then"),

    ("G4", "IMG", "the loop exits one step late on the COLUMN dimension",
     "            if sh_racc >= sh_rows and sh_cacc >= sh_cols then",
     "            if sh_racc >= sh_rows and sh_cacc > sh_cols then"),

    ("G5", "IMG", "the loop exits when EITHER dimension is covered",
     "            if sh_racc >= sh_rows and sh_cacc >= sh_cols then",
     "            if sh_racc >= sh_rows or sh_cacc >= sh_cols then"),

    ("G6", "IMG", "the row accumulator keeps running past its dimension",
     "              if sh_racc < sh_rows then",
     "              if sh_racc <= sh_rows then"),

    ("G7", "IMG", "the column accumulator keeps running past its dimension",
     "              if sh_cacc < sh_cols then",
     "              if sh_cacc <= sh_cols then"),

    ("G8", "IMG", "the one multiply is off by one tile-row",
     "              sh_prod <= sh_t * sh_nb;         -- the ONE multiply",
     "              sh_prod <= sh_t * sh_nb + 1;     -- the ONE multiply"),

    # ---------------------------------------------------------- S_SHAPE_C
    ("C1", "IMG", "weaken: w_beats is no longer required to equal tiles*nblk",
     "            if unsigned(lo32(dw(EXT0 + 1))) /= to_unsigned(sh_prod, 32)",
     "            if false"),

    ("C2", "IMG", "weaken: the w_beats equality becomes a lower bound only",
     "            if unsigned(lo32(dw(EXT0 + 1))) /= to_unsigned(sh_prod, 32)",
     "            if unsigned(lo32(dw(EXT0 + 1))) < to_unsigned(sh_prod, 32)"),

    ("C3", "IMG", "weaken: the s_beats LOWER bound is dropped (starvation)",
     "               or unsigned(hi32(dw(EXT0 + 1))) * GRP\n"
     "                    < to_unsigned(sh_prod, 64)",
     "               or false"),

    ("C4", "IMG", "weaken: the s_beats UPPER bound is dropped (over-read)",
     "               or (unsigned(hi32(dw(EXT0 + 1))) - 1) * GRP\n"
     "                    >= to_unsigned(sh_prod, 64) then",
     "               or false then"),

    ("C5", "IMG", "the s_beats bracket loses its -1, so the exact value is refused",
     "               or (unsigned(hi32(dw(EXT0 + 1))) - 1) * GRP\n"
     "                    >= to_unsigned(sh_prod, 64) then",
     "               or unsigned(hi32(dw(EXT0 + 1))) * GRP\n"
     "                    >= to_unsigned(sh_prod, 64) then"),

    ("C6", "IMG", "GRP is one too large, so every legal s_beats is refused",
     "  constant GRP     : positive := (NPORTS_S * AXI_DW) / SW_BITS;",
     "  constant GRP     : positive := (NPORTS_S * AXI_DW) / SW_BITS + 1;"),

    ("C7", "IMG", "S_SHAPE_C is skipped: the shape gate never renders a verdict",
     "              sh_prod <= sh_t * sh_nb;         -- the ONE multiply\n"
     "              st <= S_SHAPE_C;",
     "              sh_prod <= sh_t * sh_nb;         -- the ONE multiply\n"
     "              st <= S_CB;"),

    # ----------------------------------------------------------- the fetch
    ("F1", "IMG", "the fetch stops one beat early, so the tail is stale",
     "                if f_got = DBEATS-1 then",
     "                if f_got = DBEATS-2 then"),

    ("F2", "IMG", "the beat-to-word index is off by one word",
     "                  widx := f_got * WPB + j;",
     "                  widx := f_got * WPB + j + 1;"),

    ("F3", "IMG", "weaken: the descriptor fetch watchdog never fires",
     "            if wdog = WDOG_LIMIT then",
     "            if false then"),

    ("F4", "IMG", "the watchdog fires at a sixteenth of its limit",
     "            if wdog = WDOG_LIMIT then",
     "            if wdog = WDOG_LIMIT/16 then"),

    ("F5", "IMG", "the word-capture bound admits one word past the array",
     "                  if widx < DWORDS then",
     "                  if widx <= DWORDS then"),

    # -------------------------------------------------------- the codebook
    ("K1", "IMG", "weaken: a job may reuse a codebook that was never loaded",
     "            elsif dw(0)(10) = '0' and cb_valid = '0' then",
     "            elsif false then"),

    ("K2", "IMG", "the cb_load flag is read one bit low",
     "            elsif dw(0)(10) = '0' and cb_valid = '0' then",
     "            elsif dw(0)(9) = '0' and cb_valid = '0' then"),

    ("K3", "IMG", "the codebook load stops one entry short",
     "            elsif cb_cnt = 16 then",
     "            elsif cb_cnt = 15 then"),

    ("K4", "IMG", "the codebook's high half is loaded from the low word",
     "                cb_data <= dw(6)((cb_cnt-8+1)*8-1 downto (cb_cnt-8)*8);",
     "                cb_data <= dw(5)((cb_cnt-8+1)*8-1 downto (cb_cnt-8)*8);"),

    ("K5", "IMG", "cb_valid is set even when nothing was loaded",
     "  signal cb_valid : std_logic := '0';",
     "  signal cb_valid : std_logic := '1';"),

    # ------------------------------------------------------- the AXI-Lite
    ("W1", "IMG", "GO is taken from the wrong CTRL bit",
     "            when 2 => if s_axi_wdata(0) = '1' then go <= '1'; end if;",
     "            when 2 => if s_axi_wdata(1) = '1' then go <= '1'; end if;"),

    ("W2", "IMG", "weaken: the WRITE-TIME ERR_ADDR check is one bit too loose",
     "                if 32 + i >= ADDR_W and s_axi_wdata(i) /= '0' then",
     "                if 32 + i > ADDR_W and s_axi_wdata(i) /= '0' then"),

    ("W3", "IMG", "weaken: the WRITE-TIME ERR_ADDR check is removed",
     "                if 32 + i >= ADDR_W and s_axi_wdata(i) /= '0' then",
     "                if false then"),

    ("W4", "IMG", "GO is not captured into the sticky bit",
     "        if go = '1' then go_p <= '1'; end if;",
     "        if false then go_p <= '1'; end if;"),

    ("W5", "IMG", "STATUS reports err and busy in each other's bit",
     "                                 err_addr & sat_l & err_l & busy & done_l;",
     "                                 err_addr & sat_l & busy & err_l & done_l;"),

    ("W6", "IMG", "ERR_INFO is reported from the wrong register",
     "            when 4 => rdata_r <= (31 downto 16 => '0') & err_info;",
     "            when 4 => rdata_r <= (others => '0');"),

    ("W7", "IMG", "err_code is reported shifted by one bit",
     "            when 3 => rdata_r <= (31 downto 12 => '0') & err_code &",
     "            when 3 => rdata_r <= (31 downto 13 => '0') & err_code & '0' &"),

    ("W8", "IMG", "DESC_WORDS reports one word too many",
     "            when 8 => rdata_r <= std_logic_vector(to_unsigned(DWORDS, 32));",
     "            when 8 => rdata_r <= std_logic_vector(to_unsigned(DWORDS+1, 32));"),

    ("W9", "IMG", "CAPS reports NPORTS_W and NPORTS_S swapped",
     "                        std_logic_vector(to_unsigned(NPORTS_S, 8)) &\n"
     "                        std_logic_vector(to_unsigned(NPORTS_W, 8));",
     "                        std_logic_vector(to_unsigned(NPORTS_W, 8)) &\n"
     "                        std_logic_vector(to_unsigned(NPORTS_S, 8));"),

    # ------------------------------------------------- start / error state
    ("E1", "IMG", "`start` is never pulsed: no descriptor can ever run",
     "            core_start <= '1';\n            st <= S_WAIT;",
     "            core_start <= '0';\n            st <= S_WAIT;"),

    ("E2", "IMG", "S_ERR is no longer sticky: another GO re-arms the design",
     "          when S_ERR =>\n            busy  <= '0';\n            err_l <= '1';",
     "          when S_ERR =>\n            busy  <= '0';\n            err_l <= '1';\n"
     "            if go_p = '1' then go_p <= '0'; st <= S_IDLE; end if;"),

    ("E3", "IMG", "a refused descriptor also reports DONE",
     "              err_code <= EC_MAGIC;",
     "              err_code <= EC_MAGIC; done_l <= '1';"),

    # ---------------------------------------------------- RUN branch only
    ("R1", "RUN", "the core's own error is not turned into EC_CORE",
     "            if core_err = '1' then",
     "            if false then"),

    ("R2", "RUN", "the result tile counter never advances",
     "        if w_tile < TILES-1 then w_tile <= w_tile + 1; end if;",
     "        if false then w_tile <= w_tile + 1; end if;"),

    ("R3", "RUN", "the Y_IDX quotient loop stops one subtraction early",
     "        if yi_run >= ROWS_IF then",
     "        if yi_run > ROWS_IF then"),

    ("R4", "RUN", "Y_LO / Y_HI answer without waiting for the divide",
     "           and not ((rreg = 10 or rreg = 11) and (y_ok and y_rdy) = '0') then",
     "           then"),

    ("R5", "RUN", "the busy->done transition never happens",
     "            elsif core_done = '1' then",
     "            elsif false then"),

    # ------------------------------------------------------- GEN branch only
    ("N1", "GEN", "USE_XEXP_PORT takes x_exp from the descriptor either way",
     "  v_xexp   <= x_exp_in when USE_XEXP_PORT else lo32(dw(EXT0 + 2));",
     "  v_xexp   <= lo32(dw(EXT0 + 2));"),

    ("N2", "GEN", "the descriptor read master is given the CORE clock as m_aclk",
     "    port map(clk => s_axi_aclk, rst => rst, aclk => m_aclk,\n"
     "             start => d_start,",
     "    port map(clk => s_axi_aclk, rst => rst, aclk => s_axi_aclk,\n"
     "             start => d_start,"),
]


def main():
    if len(sys.argv) == 2 and sys.argv[1] == "--list":
        for name, branch, note, _o, _n in MUTATIONS:
            print("%s\t%s\t%s" % (name, branch, note))
        return
    if len(sys.argv) == 4 and sys.argv[1] == "--apply":
        name, path = sys.argv[2], sys.argv[3]
        for n, _b, _note, old, new in MUTATIONS:
            if n != name:
                continue
            s = open(path).read()
            if s.count(old) < 1:
                sys.stderr.write("ANCHOR NOT FOUND for %s:\n%r\n" % (name, old))
                sys.exit(3)
            open(path, "w").write(s.replace(old, new, 1))
            return
        sys.stderr.write("no such mutation: %s\n" % name)
        sys.exit(3)
    sys.stderr.write(__doc__ + "\nusage: --list | --apply NAME FILE\n")
    sys.exit(2)


if __name__ == "__main__":
    main()
