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


@pytest.mark.skipif(subprocess.run(["which", "tclsh"], capture_output=True).returncode != 0,
                    reason="tclsh not installed")
def test_cdc_scan_counts_and_refuses(tmp_path):
    """a450_cdc_scan on a REAL report (the loader's, 299 Warning rows, none of them a450's)
    must count every flagged row and refuse all of them; one synthetic row per a450 rule
    class must be allowed, and a near-miss (ar2, not ar1) refused."""
    rpt = os.path.join(REPO, "hw", "jc", "loader", "results", "2026-10-05", "full", "cdc.rpt")
    tc = "a450_i/top/inst/a/g_split.u"
    rows = [
        ("CDC-1", "Critical", "a450_i/core_reset/U0/PR_OUT_DFF[0].FDRE_PER_N/C", tc + "/ar1_reg/D"),
        ("CDC-1", "Critical", tc + "/gosync/tog_reg/C", tc + "/gosync/s1_reg/D"),
        ("CDC-6", "Warning", tc + "/cross/q/wp_g_reg[3]/C", tc + "/cross/q/wp_g_s1_reg[3]/D"),
        ("CDC-4", "Critical", tc + "/back/nb_r_reg[5]/C", tc + "/fast/dist/nb_m1_r_reg[5]/D"),
        ("CDC-1", "Critical", "a450_i/core_reset/U0/PR_OUT_DFF[0].FDRE_PER_N/C", tc + "/ar2_reg/D"),
    ]
    syn = "ID      Severity  Count  Description\n"
    syn += "CDC-1   Critical      4  1-bit unknown CDC circuitry\n"
    syn += "CDC-4   Critical      0  x\nCDC-6   Warning       1  Multi-bit synchronized\n"
    for i, (rid, sev, s, d) in enumerate(rows):
        syn += "%d  %s   %s  some description here  2  Max Delay Datapath Only  %s  %s\n" % (
            i + 1, rid, sev, s, d)
    syn_path = str(tmp_path / "syn_cdc.rpt")
    with open(syn_path, "w") as f:
        f.write(syn)
    script = """
source %s
set rules [a450_cdc_rules %s a450_i/top/inst/stub]
foreach p {%s %s} {
  set fh [open $p]; set t [read $fh]; close $fh
  lassign [a450_cdc_scan $t $rules] ns nr bad hits
  puts "SCAN $ns $nr [llength $bad] [lsort [dict keys $hits]]"
  foreach b $bad { puts "BAD $b" }
}
""" % (os.path.join(HERE, "a450_cdc.tcl"), tc, rpt, syn_path)
    r = subprocess.run(["tclsh"], input=script, capture_output=True, text=True)
    scans = re.findall(r"^SCAN (\d+) (\d+) (\d+) ?(.*)$", r.stdout, re.M)
    assert len(scans) == 2, r.stdout + r.stderr
    assert scans[0][:3] == ("299", "299", "299"), scans[0]
    assert scans[1][:3] == ("5", "5", "1"), scans[1]
    assert scans[1][3].split() == ["fifo_wp_gray", "job_nb_r", "rst_ar1", "tog_s1"]
    assert re.search(r"^BAD CDC-1 Critical .*/ar2_reg/D$", r.stdout, re.M), r.stdout
