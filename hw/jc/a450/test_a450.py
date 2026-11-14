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
