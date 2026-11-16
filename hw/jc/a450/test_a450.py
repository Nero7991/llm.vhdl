"""hw/jc/a450/test_a450.py -- structural checks over the a450 A+HBM timing design
(plan docs/superpowers/plans/2026-11-12-a450-per-port-tiles.md, Task 7).

Pure Python plus GHDL analysis; no Vivado, no hardware.  Run:
    python3 -m pytest hw/jc/a450/test_a450.py -q

What these checks are NOT: evidence that the design routes or meets 450 MHz.  They pin
what the run script and the Tcl promise (the generated top is current, the port map is
the card's, every pblock names a tile port, the run is routed and refuses the unsafe
cases), so a broken edit fails here in seconds instead of 90 minutes into a route.
"""
import os
import re
import subprocess
import sys

import pytest

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
sys.path.insert(0, os.path.join(REPO, "hw", "fk33"))
saved = sys.argv
sys.argv = ["gen_pcieep.py"]
import gen_pcieep as P  # noqa: E402
sys.argv = saved


def _read(name):
    with open(os.path.join(HERE, name)) as f:
        return f.read()


def _code(text):
    return "\n".join(l for l in text.splitlines() if not l.lstrip().startswith("#"))


def _tcl_list(text, var):
    m = re.search(r"^set %s \{([^}]*)\}" % var, text, re.M)
    assert m, var
    return [int(x) for x in m.group(1).split()]


def test_generated_top_is_current():
    r = subprocess.run([sys.executable, os.path.join(HERE, "gen_a450_hbm_top.py"), "--check"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and re.search(r"^GEN_A450_TOP_CHECK OK", r.stdout, re.M), r.stdout


def test_top_has_27_axi3_masters():
    t = _read("a450_hbm_top.vhd")
    for i in range(27):
        assert re.search(r"\bm%02d_axi_arvalid\b" % i, t), i
    assert not re.search(r"\bm27_axi_arvalid\b", t)


def test_portmap_is_the_card_s_engine_map():
    bd = _read("a450_bd.tcl")
    assert _tcl_list(bd, "PORTMAP") == list(P.ENG_PORT_MAP[:27])


def test_pblocks_name_the_24_tile_ports():
    b = _read("build_a450.tcl")
    m = re.search(r"a450_pblocks \{[^}]*\} \"[^\"]*\" \\\s*\{([^}]*)\}", b)
    assert m, "a450_pblocks call not found"
    assert [int(x) for x in m.group(1).split()] == list(P.ENG_PORT_MAP[:24])


def test_build_routes_and_reports_routed_wns():
    b = _code(_read("build_a450.tcl"))
    assert re.search(r"^\s*route_design\b", b, re.M)
    r = b.index("route_design")
    for s in ("A450HBM_WNS_ACLK", "A450HBM_WNS_CORE", "A450HBM_DONE"):
        assert b.index(s, r) > r, "%s is not printed after route_design" % s
    assert re.search(r"^\s*source \$here/a450_cdc\.tcl", b, re.M)


def test_run_script_dry_run_and_refusals():
    sh = os.path.join(HERE, "run_a450.sh")
    r = subprocess.run(["bash", sh, "--dry-run", "/mnt/storage/fk33_builds/a450_test_dry_never"],
                       capture_output=True, text=True)
    assert r.returncode == 0 and re.search(r"^A450RUN_DRY$", r.stdout, re.M), r.stdout
    assert "run_capped.sh" in r.stdout and " 24G " in r.stdout
    for bad in ("/tmp/a450x", "relative/a450"):
        r = subprocess.run(["bash", sh, "--dry-run", bad], capture_output=True, text=True)
        assert r.returncode != 0 and re.search(r"^A450RUN_FAIL ", r.stdout, re.M), bad
    s = _read("run_a450.sh")
    assert "pgrep" not in s and "pkill" not in s
    assert "/proc" in s and "readlink" in s
    assert re.search(r"grep -nE \"\^A450HBM_NONCE", s)
    assert re.search(r"grep -nE '\^A450HBM_DONE'", s)


@pytest.mark.skipif(subprocess.run(["which", "ghdl"], capture_output=True).returncode != 0,
                    reason="ghdl not installed")
def test_rtl_closure_analyses(tmp_path):
    b = _read("build_a450.tcl")
    files = re.search(r"^set RTL08 \{([^}]*)\}", b, re.M).group(1).split()
    files.append("hw/jc/a450/a450_hbm_top.vhd")
    for f in files:
        r = subprocess.run(["ghdl", "-a", "--std=08", "-frelaxed", "--workdir=%s" % tmp_path,
                            os.path.join(REPO, f)], capture_output=True, text=True)
        assert r.returncode == 0 and "error" not in r.stderr.lower(), (f, r.stderr)


TCLSH = subprocess.run(["which", "tclsh"], capture_output=True).returncode == 0
TC = "a450_i/top/inst/a/g_split.u"
STUB = "a450_i/top/inst/stub"


def _scan(paths, extra=""):
    """Run a450_cdc_scan + a450_cdc_verdict on each report; returns (scans, stdout)."""
    script = """
source %s
set rules [a450_cdc_rules %s %s]
foreach p {%s} {
  set fh [open $p]; set t [read $fh]; close $fh
  lassign [a450_cdc_scan $t $rules] ns nr bad hits
  puts "SCAN $ns $nr [llength $bad] [lsort [dict keys $hits]]"
  foreach b $bad { puts "BAD $b" }
  foreach f [a450_cdc_verdict $ns $nr $bad $hits] { puts "VERDICT_FAIL $f" }
  puts "END"
}
%s
""" % (os.path.join(HERE, "a450_cdc.tcl"), TC, STUB, " ".join(paths), extra)
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    blocks = r.stdout.split("END\n")
    scans = []
    for b in blocks:
        m = re.search(r"^SCAN (\d+) (\d+) (\d+) ?(.*)$", b, re.M)
        if m:
            scans.append((m.groups(), re.findall(r"^BAD (.*)$", b, re.M),
                          re.findall(r"^VERDICT_FAIL (.*)$", b, re.M)))
    return scans, r.stdout + r.stderr


def _synth_report(tmp_path, name, rows):
    syn = "ID      Severity  Count  Description\n"
    for sev in ("Critical", "Warning"):
        n = sum(1 for (_, s, _, _) in rows if s == sev)
        syn += "CDC-1   %s      %d  x\n" % (sev, n)
    for i, (rid, sev, s, d) in enumerate(rows):
        syn += "%d  %s   %s  some description here  2  Max Delay Datapath Only  %s  %s\n" % (
            i + 1, rid, sev, s, d)
    path = str(tmp_path / name)
    with open(path, "w") as f:
        f.write(syn)
    return path


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_cdc_scan_counts_and_refuses(tmp_path):
    """a450_cdc_scan on a REAL report (the loader's, 299 Warning rows, none of them a450's)
    must count every flagged row and refuse all of them; one synthetic row per a450 rule
    class must be allowed, and each near-miss refused: ar2 (not ar1), a crossing out of
    xmem into a tile (the old xmem rules accepted any), a job value into a tile (the old
    job rules accepted any fast/ destination), a vendor-looking reset path (the old
    `*/*_reset/*` matched every path)."""
    rpt = os.path.join(REPO, "hw", "jc", "loader", "results", "2026-10-05", "full", "cdc.rpt")
    ok = [
        ("CDC-1", "Critical", "a450_i/core_reset/U0/PR_OUT_DFF[0].FDRE_PER_N/C", TC + "/ar1_reg/D"),
        ("CDC-1", "Critical", TC + "/gosync/tog_reg/C", TC + "/gosync/s1_reg/D"),
        ("CDC-6", "Warning", TC + "/cross/q/wp_g_reg[3:0]/C", TC + "/cross/q/wp_g_s1_reg[3:0]/D"),
        ("CDC-6", "Warning", TC + "/cross/q/rp_g_reg[3]/C", TC + "/cross/q/rp_g_s1_reg[3]/D"),
        ("CDC-4", "Critical", TC + "/back/nb_r_reg[5]/C", TC + "/fast/dist/nb_m1_r_reg[5]/D"),
        ("CDC-15", "Warning", STUB + "/wb_r_reg[52]/C",
         TC + "/fast/g_t[3].tile/wport/fsm/p_base_reg[12]/D"),
        ("CDC-15", "Warning", STUB + "/w_beats_reg[1]/C",
         TC + "/fast/dist/gen_s[2].sport/fsm/p_beats_reg[1]/D"),
    ]
    bad = [
        ("CDC-1", "Critical", "a450_i/core_reset/U0/PR_OUT_DFF[0].FDRE_PER_N/C", TC + "/ar2_reg/D"),
        ("CDC-13", "Critical", TC + "/xmem/foo_reg/C", TC + "/fast/g_t[3].tile/bar_reg/D"),
        ("CDC-15", "Warning", TC + "/back/nb_r_reg[5]/C", TC + "/fast/g_t[3].tile/nb_m1_r_reg[5]/D"),
        ("CDC-1", "Critical", TC + "/back/foo_reg/C", "a450_i/aclk_reset/U0/bar_reg/D"),
        ("CDC-15", "Warning", STUB + "/wb_r_reg[52]/C",
         TC + "/fast/g_t[3].tile/wport/fsm/x/p_base_reg[12]/D"),
    ]
    syn = _synth_report(tmp_path, "syn_cdc.rpt", ok + bad)
    scans, out = _scan([rpt, syn])
    assert len(scans) == 2, out
    assert scans[0][0][:3] == ("299", "299", "299"), scans[0]
    assert scans[1][0][:3] == ("12", "12", "5"), (scans[1], out)
    assert scans[1][0][3].split() == ["fifo_rp_gray", "fifo_wp_gray", "job_nb_r", "rst_ar1",
                                      "stub_base", "stub_beats", "tog_s1"], scans[1]
    got = sorted(b.split()[2] + " -> " + b.split()[4] for b in scans[1][1])
    want = sorted(s + " -> " + d for (_, _, s, d) in bad)
    assert got == want, (got, want)


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_cdc_rules_cover_r2_exactly():
    """Every Critical/Warning row of the routed a450_hbm_r2 report matches a rule, and the
    verdict passes; a rule nobody matched would be listed below (none is, except the
    three Info synchronisers the Task 6 ruling keeps and the stub bases r2 did not have)."""
    rpt = os.path.join(HERE, "results", "a450_hbm_r2", "cdc.rpt")
    scans, out = _scan([rpt])
    (ns, nr, nb, labels), bad, verdict = scans[0]
    assert (ns, nr, nb) == ("439", "439", "0"), (scans[0], out)
    assert verdict == [], verdict
    assert set(labels.split()) == {"fifo_rp_gray", "fifo_wp_gray", "job_cbk", "job_lastv_r",
                                   "job_md_r", "job_nb_r", "job_os_r", "job_rows_r",
                                   "stub_beats"}, labels


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_cdc_verdict_refuses_vacuous(tmp_path):
    """No flagged row at all, or no Gray-pointer row, is refused, not passed."""
    empty = _synth_report(tmp_path, "empty.rpt", [])
    nogray = _synth_report(tmp_path, "nogray.rpt", [
        ("CDC-4", "Critical", TC + "/back/nb_r_reg[5]/C", TC + "/fast/dist/nb_m1_r_reg[5]/D")])
    scans, out = _scan([empty, nogray])
    assert len(scans) == 2, out
    assert any("vacuous" in f for f in scans[0][2]), scans[0]
    assert any("no fifo_wp_gray" in f for f in scans[1][2]), scans[1]
    assert any("no fifo_rp_gray" in f for f in scans[1][2]), scans[1]


def test_directives_flag():
    """Task 7b group E, fix round 2: the default run says -directives explore,
    --directives default selects Vivado's defaults, anything else is refused; the build has both
    implementation sequences and refuses an unknown value."""
    sh = os.path.join(HERE, "run_a450.sh")
    root = "/mnt/storage/fk33_builds/a450_test_dry_never"
    r = subprocess.run(["bash", sh, "--dry-run", root], capture_output=True, text=True)
    assert r.returncode == 0 and "-directives explore" in r.stdout, r.stdout
    r = subprocess.run(["bash", sh, "--dry-run", "--directives", "default", root],
                       capture_output=True, text=True)
    assert r.returncode == 0 and "-directives default" in r.stdout, r.stdout
    r = subprocess.run(["bash", sh, "--dry-run", "--directives", "fast", root],
                       capture_output=True, text=True)
    assert r.returncode != 0 and re.search(r"^A450RUN_FAIL ", r.stdout, re.M), r.stdout
    b = _code(_read("build_a450.tcl"))
    for d in ("opt_design -directive ExploreWithRemap", "place_design -directive ExtraTimingOpt",
              "route_design -directive AggressiveExplore"):
        assert d in b, d
    assert b.count("phys_opt_design -directive AggressiveExplore") == 2
    assert "A450HBM_DIRECTIVES" in b and "is not default or explore" in b


def test_overconstrain_flag():
    """Task 7b fix round 1: --overconstrain-ns reaches the build, refuses a non-number, and
    the build adds setup uncertainty on aclk_a only, after the constraints."""
    sh = os.path.join(HERE, "run_a450.sh")
    root = "/mnt/storage/fk33_builds/a450_test_dry_never"
    r = subprocess.run(["bash", sh, "--dry-run", "--overconstrain-ns", "2.15", root],
                       capture_output=True, text=True)
    assert r.returncode == 0 and "-overconstrain 2.15" in r.stdout, r.stdout
    r = subprocess.run(["bash", sh, "--dry-run", root], capture_output=True, text=True)
    assert "-overconstrain none" in r.stdout, r.stdout
    r = subprocess.run(["bash", sh, "--dry-run", "--overconstrain-ns", "x", root],
                       capture_output=True, text=True)
    assert r.returncode != 0 and re.search(r"^A450RUN_FAIL ", r.stdout, re.M), r.stdout
    b = _code(_read("build_a450.tcl"))
    assert "set_clock_uncertainty -setup $extra -from $ca -to $ca" in b
    assert b.index("set_clock_uncertainty") < b.index("opt_design")


# ---- Task 9b: the gate carries the split-on card's aclk_a-side IP ----------------------
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "card"))
sys.path.insert(0, os.path.join(REPO, "hw", "jc", "link"))
import gen_jc_card as G  # noqa: E402


def test_gate_ip_is_the_cards():
    """The gate's IP_CHAIN, register-slice CONFIG and smartconnect CONFIG are the card's
    (gen_jc_card.py), and a450_ip_chains (the one list both builds floorplan) names
    exactly those cells on those ports."""
    bd = _read("a450_bd.tcl")
    m = re.search(r"^set IP_CHAIN \{([^}]*)\}", bd, re.M)
    toks = m.group(1).split()
    gate = [(toks[i + 1], toks[i + 2], int(toks[i + 3])) for i in range(0, len(toks), 4)]
    assert gate == [("ld_cdc", "ld_rs", 0), ("d_cdc", "d_rs", 29), ("bc_cdc0", "bc_rs0", 30),
                    ("bc_cdc1", "bc_rs1", 31)]
    assert re.search(r"^set SC_SAXI 16$", bd, re.M)
    t = G.render_tcl(P, G.CLK_CORE_DEFAULT, {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"})
    for cc, rs, port in gate + [("hbm_sc", "sc_rs", 16)]:
        assert re.search(r"\[get_bd_intf_pins %s/M_AXI\] \[get_bd_intf_pins hbm/SAXI_%02d\]" % (rs, port), t)
        assert re.search(r"\[get_bd_intf_pins %s/M(00)?_AXI\] \[get_bd_intf_pins %s/S_AXI\]" % (cc, rs), t)
    cfg = re.search(r"proc a4_rs \{name\} \{.*?set_property -dict \[list ([^\]]*)\]", bd, re.S).group(1)
    gate_rs = re.findall(r"CONFIG\.(\w+) \{(\w+)\}", cfg)
    assert gate_rs == list(G.RS_CONFIG)
    sc = re.search(r"CONFIG\.NUM_SI \{(\d)\} CONFIG\.NUM_MI \{(\d)\} CONFIG\.NUM_CLKS \{(\d)\}\] \[get_bd_cells hbm_sc\]", bd)
    card_sc = re.search(r"CONFIG\.NUM_SI \{(\d)\} CONFIG\.NUM_MI \{(\d)\} CONFIG\.NUM_CLKS \{(\d)\}\] \[get_bd_cells hbm_sc\]", t)
    assert sc and card_sc and sc.groups() == card_sc.groups() == ("3", "1", "2")
    jt = r"CONFIG\.M_AXI_DATA_WIDTH \{64\} CONFIG\.M_AXI_ADDR_WIDTH \{64\}\] \[get_bd_cells jtag_hbm\]"
    assert re.search(jt, bd) and re.search(jt, t)
    pb = _read("a450_pblocks.tcl")
    m = re.search(r"proc a450_ip_chains \{bd_re\} \{.*?foreach \{c n\} \{([^}]*)\}", pb, re.S)
    lst = m.group(1).split()
    named = sorted((lst[i], int(lst[i + 1])) for i in range(0, len(lst), 2))
    want = sorted([(cc, p) for cc, _, p in gate] + [(rs, p) for _, rs, p in gate] +
                  [("hbm_sc", 16), ("sc_rs", 16)])
    assert named == want


def test_gate_enables_all_32_ports_with_the_card_switch_clocks():
    bd = _code(_read("a450_bd.tcl"))
    assert "a4_want hbm USER_CLK_SEL_LIST0 AXI_00_ACLK" in bd
    assert "a4_want hbm USER_CLK_SEL_LIST1 AXI_16_ACLK" in bd
    assert "[llength $SAXI_ON] != 32" in bd
    t = _read("a450_hbm_top.vhd")
    for n in ("x_ld", "x_d", "x_bc0", "x_bc1", "x_ctl", "x_tok"):
        assert re.search(r"\b%s_axi_arvalid\b" % n, t), n
        assert re.search(r"tg_%s : entity work\.a450_tg" % n, t), n
    assert re.search(r"tg_x_d : entity work\.a450_tg\n    generic map\(LEN_W => 4, WR => false", t)


def test_gate_checks_the_floorplan_as_placed_before_routing():
    b = _code(_read("build_a450.tcl"))
    for seq in (b[b.index('if {$dirs eq "explore"}'):b.index("} else {", b.index('if {$dirs eq "explore"}'))],
                b[b.index("} else {", b.index('if {$dirs eq "explore"}')):]):
        i = [seq.index(s) for s in ("place_design", "a4_placed", "route_design")]
        assert i == sorted(i), seq[:400]
    assert "a450_ip_pblocks [a450_ip_chains {a450_i}]" in b
    assert "[a450_cdc_ip_rules a450_i]" in b
    assert "A450HBM_FAILING_ACLK" in b


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_cdc_ip_rules_name_only_the_ip_fifo_rows():
    """a450_cdc_ip_rules on the split-on card's report: all 690 hbm_sc/dbg_hub rows matched
    (MEASURED, jccard_a450s1b); near misses (a FIFO read register OUTSIDE hbm_sc, an hbm_sc
    row into a non-FIFO register) refused."""
    bd = "u_bd/jcc_i"
    M = ("inst/m00_nodes/m00_r_node/inst/inst_mi_handler/gen_normal_area.inst_fifo_node_payld/"
         "gen_xpm_memory_fifo.inst_fifo/gen_mem_rep[0].inst_xpm_memory/xpm_memory_base_inst")
    ok = "%s/hbm_sc/%s/gen_wr_a.gen_word_narrow.mem_reg_0_31_0_13/RAMA/CLK" % (bd, M)
    rd = "%s/hbm_sc/%s/gen_rd_b.gen_rd_b_synth_template.gen_rf_narrow_reg.doutb_reg_reg[3]/D" % (bd, M)
    script = """
source %s
set r [a450_cdc_ip_rules %s]
proc hit {s d} { foreach x $::r { lassign $x l sp dp; if {[regexp -- $sp $s] && [regexp -- $dp $d]} { return $l } }; return none }
puts "A [hit {%s} {%s}]"
puts "B [hit {%s} {%s}]"
puts "C [hit {%s} {%s}]"
""" % (os.path.join(HERE, "a450_cdc.tcl"), bd, ok, rd, ok, rd.replace("/hbm_sc/", "/ld_cdc/"),
       ok, "%s/hbm_sc/inst/m00_nodes/foo_reg/D" % bd)
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    assert re.findall(r"^([ABC]) (\S+)$", r.stdout, re.M) == [("A", "hbm_sc_node_fifo"), ("B", "none"),
                                                              ("C", "none")], r.stdout + r.stderr


# ---- Task 9b fix round 1 (review m5): teeth for the placed-floorplan share -------------
SHARES = os.path.join(HERE, "testdata", "placed_shares.txt")


def _placed(run):
    """a450_pblocks_placed itself (a450_pblocks.tcl, sourced under tclsh) on one run's
    per-tile region counts, with the Vivado queries stubbed: get_cells answers the exact
    NAME it is asked for, a450_pb_regions answers from the fixture."""
    script = """
source %s
proc get_pblocks {args} { return {} }
proc get_cells {args} { regexp {NAME == "([^"]*)"} [lindex $args end] -> n; return [list $n] }
set ::H [dict create]
set ::a450_pb_expect {}
set fh [open %s]
foreach l [split [read $fh] "\\n"] {
  if {[regexp {^%s (\\d+) (\\d+) \\{(.*)\\}$} $l -> p x h]} {
    dict set ::H tile$p $h
    lappend ::a450_pb_expect [list $p 0 {} {} tile$p $x]
  }
}
close $fh
proc a450_pb_regions {c} { set h [dict get $::H $c]; set n 0; dict for {r k} $h { incr n $k }; return [list $h $n 0] }
lassign [a450_pblocks_placed] bad npb nt ni smin
puts "RESULT [llength $::a450_pb_expect] bad [llength $bad] ok $nt min [format %%.3f $smin]"
""" % (os.path.join(HERE, "a450_pblocks.tcl"), SHARES, run)
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    m = re.search(r"^RESULT (\d+) bad (\d+) ok (\d+) min (\S+)$", r.stdout, re.M)
    assert m, r.stdout + r.stderr
    return tuple(int(g) for g in m.groups()[:3]) + (float(m.group(4)),)


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_placed_share_refuses_the_unfloorplanned_card_and_accepts_the_closing_runs():
    """MEASURED fixtures: jccard_a450s1b (no pblocks, AltSpreadLogic_high) has 19 of 24 tiles
    under 0.80 (min 0.022) and is refused; a450_hbm_7b_r6 (closed 450 MHz) and
    a450_hbm_9b_r2 (closed with the card's IP) pass all 24 (min 0.906, 0.910).  Per tile the
    threshold does not separate the two (5 unfloorplanned tiles pass); the build-level verdict
    (any failing tile refuses) does."""
    assert _placed("jccard_a450s1b") == (24, 19, 5, 0.022)
    assert _placed("r6") == (24, 0, 24, 0.906)
    assert _placed("9b_r2") == (24, 0, 24, 0.910)


# ---- final review I3: the gate's reset tree, hbm_aresetn and start read-back are the card's --
_CONN = re.compile(r"connect_bd_net \[get_bd_pins (\S+)\]\s+\[get_bd_pins (\S+)\]")
_RST_IN = ("core_reset", "aclk_reset", "apb_rst", "lock_and")


def _reset_inputs(text):
    """{input pin of a reset-tree cell: its driver}, from two-endpoint connect_bd_net lines."""
    d = {}
    for a, b in _CONN.findall(text):
        if b.split("/")[0] in _RST_IN and b.split("/")[1] in (
                "ext_reset_in", "dcm_locked", "slowest_sync_clk", "Op1", "Op2"):
            assert b not in d, "two drivers for %s" % b
            d[b] = a
    return d


def _split_render():
    return G.render_tcl(P, G.CLK_CORE_DEFAULT, {"JC_A_TILED": "1", "JC_A_CLK_SPLIT": "1"})


def test_gate_reset_tree_is_the_split_on_cards():
    """Every input of core_reset, aclk_reset, apb_rst and lock_and has the same driver in the
    gate as in the split-on card render (core_reset descends from aclk_reset, aclk_reset
    takes both locks), and lock_and's CONFIG is the card's.  The old sibling tree fails
    this (core_reset/ext_reset_in on one/dout, dcm_locked on clk_wiz_0/locked)."""
    gate = _reset_inputs(_code(_read("a450_bd.tcl")))
    card = _reset_inputs(_split_render())
    assert gate == card
    assert gate["core_reset/ext_reset_in"] == "aclk_reset/peripheral_aresetn"
    assert gate["core_reset/dcm_locked"] == "one/dout"
    assert gate["aclk_reset/dcm_locked"] == "lock_and/Res"
    cfg = r"CONFIG\.C_SIZE \{1\} CONFIG\.C_OPERATION \{and\}\] \[get_bd_cells lock_and\]"
    assert re.search(cfg, _read("a450_bd.tcl")) and re.search(cfg, _split_render())
    # the propagated polarity is read back after validation, as the card does
    bd = _code(_read("a450_bd.tcl"))
    assert bd.index("validate_bd_design") < bd.index("C_EXT_RESET_HIGH") < bd.index("save_bd_design")


def test_reset_tree_check_has_teeth():
    """The attribution control: the pre-fix sibling tree, rebuilt from the gate's own text,
    is refused by the comparison above."""
    bd = _code(_read("a450_bd.tcl"))
    old = bd.replace("[get_bd_pins aclk_reset/peripheral_aresetn] [get_bd_pins core_reset/ext_reset_in]",
                     "[get_bd_pins one/dout] [get_bd_pins core_reset/ext_reset_in]")
    old = old.replace("[get_bd_pins one/dout] [get_bd_pins core_reset/dcm_locked]",
                      "[get_bd_pins clk_wiz_0/locked] [get_bd_pins core_reset/dcm_locked]")
    assert old != bd
    assert _reset_inputs(old) != _reset_inputs(_split_render())


def test_gate_wires_hbm_aresetn_as_the_card_does():
    """The card drives eng/hbm_aresetn from aclk_reset's peripheral_aresetn; the gate drives
    top/hbm_aresetn from the same net, the top passes it to mv4i_tiled, and the top port
    has no default (an unconnected module-reference input would be tied to zero silently)."""
    card = dict((b, a) for a, b in _CONN.findall(_split_render()))
    assert card["%s/hbm_aresetn" % P.ENG_CELL] == G.ACLK_A_RSTN
    gate = dict((b, a) for a, b in _CONN.findall(_code(_read("a450_bd.tcl"))))
    assert gate["top/hbm_aresetn"] == G.ACLK_A_RSTN
    top = _read("a450_hbm_top.vhd")
    assert re.search(r"^    hbm_aresetn : in std_logic;$", top, re.M)
    assert re.search(r"a : entity work\.mv4i_tiled\b.*?hbm_aresetn => hbm_aresetn", top, re.S)


def _readback(case):
    """Run a450_start_readback against stubbed Vivado queries; case sets the two paths'
    properties ({} for a path that is missing).  Returns (stdout lines, fails)."""
    rst, tog = case
    def props(p):
        return " ".join("%s %s" % kv for kv in p.items())
    script = r"""
source %s
set ::TC %s
array set ::P_rst {%s}
array set ::P_tog {%s}
proc _objs {args} {
  set out {}
  set skip 0
  foreach a $args {
    if {$skip} { set skip 0; continue }
    if {$a in {-filter -of_objects}} { set skip 1; continue }
    if {[string match -* $a]} { continue }
    lappend out $a
  }
  return [join $out]
}
proc get_pins {args} {
  set n [_objs {*}$args]
  if {$n in [list $::TC/ar1_reg/D $::TC/ar1_reg/C $::TC/gosync/s1_reg/D]} { return $n }
  return {}
}
proc get_clocks {args} { return clk_a }
proc get_cells {args} {
  set n [_objs {*}$args]
  if {$n in {rst_src} || $n eq "$::TC/gosync/tog_reg"} { return $n }
  return {}
}
proc all_fanin {args} { return rst_src }
proc get_timing_paths {args} {
  set to [lindex $args [expr {[lsearch $args -to] + 1}]]
  if {$to eq "$::TC/ar1_reg/D"} { return [expr {[array size ::P_rst] ? "P_rst" : ""}] }
  return [expr {[array size ::P_tog] ? "P_tog" : ""}]
}
proc get_property {k o} {
  if {$o eq "clk_a"} { return 2.222 }
  return [set ::${o}($k)]
}
lassign [a450_start_readback $::TC] prst ptog pa sk fails
puts "PATHS $prst $ptog PERIOD $pa SKEW $sk"
foreach f $fails { puts "FAIL $f" }
""" % (os.path.join(HERE, "a450_cdc.tcl"), TC, props(rst), props(tog))
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return r.stdout, re.findall(r"^FAIL (.*)$", r.stdout, re.M)


@pytest.mark.skipif(not TCLSH, reason="tclsh not installed")
def test_start_readback_refuses_on_the_gate_conditions():
    """a450_start_readback, the proc both the gate and the split-on card call, against the
    9b_r2 MEASURED values (pass) and one mutation per refusal."""
    good_r = {"REQUIREMENT": 2.222, "SLACK": 1.784, "DATAPATH_DELAY": 0.463}
    good_t = {"REQUIREMENT": 2.222, "SLACK": 1.443, "DATAPATH_DELAY": 0.804}
    out, f = _readback((good_r, good_t))
    assert f == [] and "PATHS P_rst P_tog PERIOD 2.222" in out, out
    _, f = _readback((dict(good_r, REQUIREMENT=4.444), good_t))
    assert len(f) == 1 and f[0].startswith("rst->ar1 requirement 4.444"), f
    _, f = _readback((good_r, dict(good_t, SLACK=-0.01)))
    assert len(f) == 1 and f[0].startswith("tog->s1 misses"), f
    _, f = _readback((dict(good_r, DATAPATH_DELAY=0.1), dict(good_t, DATAPATH_DELAY=2.4)))
    assert len(f) == 1 and "skew" in f[0], f
    _, f = _readback((good_r, {}))
    assert f == ["start-crossing reset paths: 1 rst->ar1, 0 tog->s1"], f


def test_card_reads_back_the_start_paths_after_route_when_split():
    """build_card.tcl calls the gate's proc on the routed design under ::a450_split, prints
    ^JCCARD_A450_ lines and refuses through jcc_fail; the gate calls the same proc."""
    with open(os.path.join(REPO, "hw", "jc", "card", "build_card.tcl")) as f:
        b = _code(f.read())
    i = b.index("lassign [a450_start_readback $::a450_tc]")
    assert b.rindex("route_design") < i < b.index("report_route_status -file")
    blk = b[b.rindex("if {[info exists ::a450_split] && $::a450_split} {", 0, i):b.index("report_route_status -file")]
    for s in ('puts "JCCARD_A450_$a4_tag', 'puts "JCCARD_A450_RSTSKEW', 'puts "JCCARD_A450_START_FAIL',
              'jcc_fail "a450 start-crossing read-back'):
        assert s in blk, s
    g = _code(_read("build_a450.tcl"))
    assert "lassign [a450_start_readback $tc] prst ptog pa_ns rskew sfails" in g
    assert "foreach f $sfails { a4_check_fail $f }" in g
