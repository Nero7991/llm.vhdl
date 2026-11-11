"""hw/jc/card/test_jc_link_timing.py -- the jccard_loop2 timing fixes (2026-11-11).

Root cause 1: the link CDC bounds were applied before the gtg ECO with "-from <clock>"; the
ECO re-derived the Aurora clocks (txoutclk_out[0] -> txoutclk_out[0]_1), the bounds stopped
applying and report_exceptions died on the dangling object. Root cause 2: cb_data/cb_addr
fanout (1536 loads each) stretched by placement pressure.

The clock-interaction parse runs jc_link_timing.tcl's OWN proc under tclsh against the two
REAL reports from jccard_loop2's routed checkpoint: as built (one "Timed (unsafe)" row,
user_clk -> aclk) and after sourcing the fixed constraints on it (none). The rest are static
checks on the order of the steps in build_card.tcl; the Vivado-side behaviour (audit refuses
without the bounds, passes with them) was measured on the checkpoint, see
.superpowers/sdd/2026-11-04-jc-on-fabric-loop-and-link/timing-fix-report.md.

    python3 -m pytest hw/jc/card/test_jc_link_timing.py -q
"""
import os
import re
import subprocess

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.normpath(os.path.join(HERE, "..", "..", ".."))
DATA = os.path.join(HERE, "testdata")
LINK_TCL = os.path.join(REPO, "hw", "jc", "link", "jc_link_timing.tcl")
BUILD_TCL = os.path.join(HERE, "build_card.tcl")
CI_BUILT = os.path.join(DATA, "clock_interaction_jccard_loop2_routed.rpt")
CI_FIXED = os.path.join(DATA, "clock_interaction_jccard_loop2_cdcfix.rpt")
ACLK = "clk_out3_jcc_clk_wiz_0_0"
USER = "txoutclk_out[0]_1"
INIT = "o1"


def _read(p):
    with open(p) as f:
        return f.read()


def _code(text):
    return "\n".join(l for l in text.splitlines() if not l.strip().startswith("#"))


def _ci_rows(report, tmp_path):
    """jlk_ci_rows on a report file -> [(from, to, unsafe)] via tclsh."""
    script = tmp_path / "t.tcl"
    script.write_text(
        "source {%s}\n"
        "set fh [open {%s}]; set t [read $fh]; close $fh\n"
        "set pairs [list {%s} {%s} {%s} {%s} {%s} {%s} {%s} {%s}]\n"
        "foreach r [jlk_ci_rows $t $pairs] { puts \"ROW [lindex $r 0] [lindex $r 1] [lindex $r 2]\" }\n"
        % (LINK_TCL, report, ACLK, USER, USER, ACLK, ACLK, INIT, INIT, ACLK))
    r = subprocess.run(["tclsh", str(script)], capture_output=True, text=True)
    assert r.returncode == 0, r.stderr
    return [tuple(l.split()[1:4]) for l in r.stdout.splitlines() if l.startswith("ROW ")]


def test_ci_parse_finds_the_unsafe_row_in_the_built_report(tmp_path):
    rows = _ci_rows(CI_BUILT, tmp_path)
    assert (USER, ACLK, "1") in rows
    assert len(rows) == 4
    assert sum(1 for r in rows if r[2] == "1") == 1


def test_ci_parse_finds_no_unsafe_row_after_the_fix(tmp_path):
    rows = _ci_rows(CI_FIXED, tmp_path)
    assert (USER, ACLK, "0") in rows
    assert len(rows) == 4
    assert all(r[2] == "0" for r in rows)


def test_no_link_bound_is_written_from_a_clock():
    code = _code(_read(LINK_TCL))
    body = code[code.index("proc jlk_cdc "):code.index("proc jlk_cdc_audit ")]
    for line in body.splitlines():
        if "set_max_delay" in line or "set_bus_skew" in line:
            m = re.search(r"-from\s+(\S+)", line)
            assert m, line
            assert m.group(1) in ("$ws", "$rs", "$cs", "$ss") or m.group(1).startswith("[jlk_src"), line
    assert "get_clocks -quiet -filter" not in body


def test_bounds_are_applied_after_the_eco_and_opt_design():
    code = _code(_read(BUILD_TCL))
    eco = code.index("eco_aurora_gtg.tcl")
    opt = code.index("opt_design", eco)
    apply_ = code.index("jlk_cdc $CORE_TOK")
    assert code.count("jlk_cdc $CORE_TOK") == 1
    assert apply_ > opt > eco
    # the structural audit still runs on the synthesized design, before the ECO
    assert code.index("jlk_cdc_audit $CORE_TOK") < eco
    place = code.index("place_design", apply_)
    assert apply_ < place


def test_post_route_audit_refuses_and_precedes_the_reports():
    code = _code(_read(BUILD_TCL))
    rt = code.index("write_checkpoint -force $bd/jc_card_routed.dcp")
    au = code.index("jlk_exc_audit $aclk_clk $clk_u $clk_i")
    rep = code.index("report_exceptions -file")
    assert rt < au < rep
    assert re.search(r'if \{\$lk_exc != 0\} \{ jcc_fail ', code)
    # report_exceptions is a refusal by name, not an uncaught Tcl error
    assert re.search(r'if \{\[catch \{\s*report_exceptions -file \$rp/exceptions\.rpt\s*'
                     r'report_exceptions -ignored -file \$rp/exceptions_ignored\.rpt\s*'
                     r'\} err\]\} \{ jcc_fail "report_exceptions: ', code)


def test_cb_data_replication_runs_after_every_placement_and_before_routing():
    code = _code(_read(BUILD_TCL))
    places = [m.start() for m in re.finditer(r"\n\s*place_design", code)]
    assert len(places) == 2
    for p in places:
        rep = code.index("jcc_cbdata_repl", p)
        route = code.index("route_design", p)
        assert rep < route
    body = code[code.index("proc jcc_cbdata_repl"):code.index("if {$impl eq \"congestion\"} {\n  place_design")]
    assert "phys_opt_design -force_replication_on_nets $nets" in body
    assert "JCCARD_CBDATA_REPL nets=" in body
    assert re.search(r"if \{\$after <= \$before\} \{ jcc_fail ", body)
    # the sentinel is printed only once the replicas are seen (MEASURED mutant: with
    # phys_opt_design stubbed out, the proc printed JCCARD_FAIL ... drivers 12 -> 12)
    assert body.index("if {$after <= $before}") < body.index("JCCARD_CBDATA_REPL nets=")
